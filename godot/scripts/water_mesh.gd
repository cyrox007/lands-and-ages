extends RefCounted
## Отрисовка водной поверхности по действующим отметкам гидрологии.
## Прибрежные треугольники обрезаются по реальной геометрии грунта.

const ShoreVisual = preload("res://scripts/shore_visual.gd")
const WATER_OFFSET := 0.018
const SHORE_FADE_DEPTH := 0.7
# Только пересекающие сушу клетки получают более точную кромку.
const SHORE_SUBDIVISIONS := ShoreVisual.SUBDIVISIONS
const COAST_SUBDIVISIONS := ShoreVisual.COAST_SUBDIVISIONS
# Метки стоячей воды в UV2 не пересекаются с речным вектором длиной <= 1.
# Шейдер выбирает разные волны для озёр и моря без дополнительных мешей.
const STANDING_LAKE := Vector2(0.0, 2.0)
const STANDING_OCEAN := Vector2(2.0, 0.0)
# Отдельная метка поймы не пересекается с UV2 русел и стоячих водоёмов.
const FLOOD_MARKER_X := -2.0
const RIVER_WITHOUT_FLOW := Vector2(0.0, -2.0)


static func _quad(tool: SurfaceTool, a: Vector3, b: Vector3,
		c: Vector3, d: Vector3, tint: Color, ice: float = 0.0,
		flow: Vector2 = Vector2.ZERO) -> void:
	## UV2 несёт только направление реального речного стока.
	## Нулевой вектор означает стоячую воду; вершины не смещаются.
	tool.set_color(tint)
	tool.set_normal(Vector3.UP)
	tool.set_uv(Vector2(1.0, ice))
	tool.set_uv2(flow)
	for vertex in [a, b, c, a, c, d]:
		tool.add_vertex(vertex)


static func _clip_submerged_triangle(points: PackedVector2Array,
		ground: PackedFloat32Array, level: float) -> PackedVector3Array:
	# X/Y — мировая позиция; Z — глубина для берегового материала.
	var polygon := PackedVector3Array()
	var previous := points.size() - 1
	for current in range(points.size()):
		var was_wet := ground[previous] <= level
		var is_wet := ground[current] <= level
		if was_wet != is_wet:
			var fraction := clampf((level - ground[previous]) /
				(ground[current] - ground[previous]), 0.0, 1.0)
			var edge := points[previous].lerp(points[current], fraction)
			polygon.append(Vector3(edge.x, edge.y, 0.0))
		if is_wet:
			var point := points[current]
			var depth := clampf((level - ground[current]) /
				SHORE_FADE_DEPTH, 0.0, 1.0)
			polygon.append(Vector3(point.x, point.y, depth))
		previous = current
	return polygon


static func _add_polygon(tool: SurfaceTool, world: RefCounted,
		polygon: PackedVector3Array, level: float, tint: Color,
		ice: float = 0.0, water_kind: Vector2 = Vector2.ZERO) -> int:
	if polygon.size() < 3:
		return 0
	var added := 0
	tool.set_color(tint)
	tool.set_normal(Vector3.UP)
	for i in range(1, polygon.size() - 1):
		var a := Vector2(polygon[0].x, polygon[0].y)
		var b := Vector2(polygon[i].x, polygon[i].y)
		var c := Vector2(polygon[i + 1].x, polygon[i + 1].y)
		if absf((b - a).cross(c - a)) < 0.000001:
			continue
		for vertex in [polygon[0], polygon[i], polygon[i + 1]]:
			# У берега сохраняем метку озера/моря; это не речной сток.
			tool.set_uv2(water_kind)
			tool.set_uv(Vector2(vertex.z, ice))
			tool.add_vertex(world.config.to_scene(
				Vector2(vertex.x, vertex.y), level + WATER_OFFSET))
		added += 1
	return added


static func _water_cell(tool: SurfaceTool, world: RefCounted,
		cell: Vector2i, level: float, tint: Color, ice: float = 0.0,
		water_kind: Vector2 = Vector2.ZERO) -> int:
	var x := cell.x
	var y := cell.y
	var a := Vector2i(x, y)
	var b := Vector2i(x + 1, y)
	var c := Vector2i(x, y + 1)
	var d := Vector2i(x + 1, y + 1)
	var ha: float = world.vertex_at(a)
	var hb: float = world.vertex_at(b)
	var hc: float = world.vertex_at(c)
	var hd: float = world.vertex_at(d)
	if maxf(maxf(ha, hb), maxf(hc, hd)) <= level:
		_quad(tool, world.config.to_scene(Vector2(a), level + WATER_OFFSET),
			world.config.to_scene(Vector2(b), level + WATER_OFFSET),
			world.config.to_scene(Vector2(d), level + WATER_OFFSET),
			world.config.to_scene(Vector2(c), level + WATER_OFFSET), tint, ice,
			water_kind)
		return 2

	# Высоты воды совпадают с уточнённой визуальной сеткой суши.
	# Делим только береговые полигоны: открытая вода не усложняется.
	# Соседние клетки получают одинаковые точки на общей границе.
	return _subdivided_shore(tool, world, cell, level, tint, ice,
		ha, hb, hc, hd, water_kind)


static func _terrain_height(ha: float, hb: float, hc: float,
		hd: float, u: float, v: float) -> float:
	# Та же визуальная высота, что у береговых клеток Chunk.
	# Физические высоты WorldMap и водный баланс не изменяются.
	return ShoreVisual.height(ha, hb, hc, hd, u, v)

static func _subdivided_shore(tool: SurfaceTool, world: RefCounted,
		cell: Vector2i, level: float, tint: Color, ice: float,
		ha: float, hb: float, hc: float, hd: float,
		water_kind: Vector2 = Vector2.ZERO) -> int:
	# Только пересечения береговой линии получают 6×6:
	# соседний грунт использует такой же шаг триангуляции.
	var added := 0
	for j in range(COAST_SUBDIVISIONS):
		for i in range(COAST_SUBDIVISIONS):
			var u0 := float(i) / float(COAST_SUBDIVISIONS)
			var u1 := float(i + 1) / float(COAST_SUBDIVISIONS)
			var v0 := float(j) / float(COAST_SUBDIVISIONS)
			var v1 := float(j + 1) / float(COAST_SUBDIVISIONS)
			var a := Vector2(cell) + Vector2(u0, v0)
			var b := Vector2(cell) + Vector2(u1, v0)
			var c := Vector2(cell) + Vector2(u0, v1)
			var d := Vector2(cell) + Vector2(u1, v1)
			var h00 := _terrain_height(ha, hb, hc, hd, u0, v0)
			var h10 := _terrain_height(ha, hb, hc, hd, u1, v0)
			var h01 := _terrain_height(ha, hb, hc, hd, u0, v1)
			var h11 := _terrain_height(ha, hb, hc, hd, u1, v1)
			var first := _clip_submerged_triangle(
				PackedVector2Array([a, c, b]),
				PackedFloat32Array([h00, h01, h10]), level)
			var second := _clip_submerged_triangle(
				PackedVector2Array([d, b, c]),
				PackedFloat32Array([h11, h10, h01]), level)
			added += _add_polygon(tool, world, first, level, tint, ice,
				water_kind)
			added += _add_polygon(tool, world, second, level, tint, ice,
				water_kind)
	return added


const RIVER_SEGMENTS := 4
const RIVER_BEND_SEGMENTS := 8
const RIVER_WIDTH_REFERENCE_FLOW := 180.0


static func _river_frame(world: RefCounted, hydro: RefCounted, cell: Vector2i) -> Dictionary:
	var center := Vector2(cell) + Vector2(0.5, 0.5)
	var index: int = hydro.cell_index(cell)
	if index < 0:
		return {"center": center, "direction": Vector2.DOWN, "headwater": true}
	var downstream: int = hydro.downstream_of(index)
	var outgoing := Vector2.ZERO
	if downstream >= 0:
		var target: Vector2i = hydro.cell_from_index(downstream)
		outgoing = Vector2(target - cell).normalized()
	var upstream := Vector2.ZERO
	var river_upstream := Vector2i.ZERO
	var river_branches := 0
	var greatest := -1.0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var upstream_cell := cell + Vector2i(dx, dy)
			var candidate: int = hydro.cell_index(upstream_cell)
			if candidate < 0 or hydro.downstream_of(candidate) != index:
				continue
			if hydro.river_at(candidate):
				river_upstream = upstream_cell
				river_branches += 1
			var flow: float = hydro.discharge_at_index(candidate)
			if flow > greatest:
				greatest = flow
				upstream = Vector2(cell - upstream_cell).normalized()
	# На ступенчатом участке немного срезаем угол внутри мокрой
	# клетки. Истоки, устья и места слияния сохраняют общий центр.
	if river_branches == 1 and hydro.river_at(index) and not hydro.lake_at(index) \
			and downstream >= 0 \
			and hydro.river_at(downstream) and not hydro.lake_at(downstream):
		var next_cell: Vector2i = hydro.cell_from_index(downstream)
		var bend := Vector2(river_upstream + next_cell - 2 * cell) * 0.24
		var shifted := center + bend.limit_length(0.22)
		if world.height_at(shifted) <= hydro.level_at(index):
			center = shifted
	var direction := upstream + outgoing
	if direction.length_squared() <= 0.0001:
		direction = outgoing if outgoing != Vector2.ZERO else Vector2.DOWN
	direction = direction.normalized()
	return {"center": center, "direction": direction, "headwater": river_branches == 0}


static func _river_curve(p0: Vector2, p1: Vector2,
		p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var it := 1.0 - t
	return p0 * (it * it * it) + p1 * (3.0 * it * it * t) \
		+ p2 * (3.0 * it * t * t) + p3 * (t * t * t)


static func _river_curve_direction(p0: Vector2, p1: Vector2,
		p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var it := 1.0 - t
	var derivative := (p1 - p0) * (it * it) \
		+ (p2 - p1) * (2.0 * it * t) + (p3 - p2) * (t * t)
	return derivative.normalized() if derivative.length_squared() > 0.000001 \
		else (p3 - p0).normalized()


static func _river_segment_count(start: Vector2, finish: Vector2) -> int:
	# Прямые участки остаются дешёвыми, но при смене направления
	# более чем примерно на 22° добавляем вершины кривой Безье.
	# Важно не превращать весь речной граф в равномерную сетку 8×.
	return RIVER_BEND_SEGMENTS if start.dot(finish) < 0.93 else RIVER_SEGMENTS


static func _river_width(discharge: float) -> float:
	# Ширина только изображает существующий физический расход.
	# Корень уменьшает контраст между соседними ячейками, а
	# верхняя граница ограничивает число пересечений с берегом.
	var relative := maxf(0.0, discharge) / RIVER_WIDTH_REFERENCE_FLOW
	return clampf(0.22 + sqrt(relative) * 0.10, 0.24, 0.55)


static func _river_visual_ground(world: RefCounted, point: Vector2) -> float:
	# Сравниваем кромку не с физической диагональю треугольника,
	# а с билинейным грунтом, который действительно рисует Chunk.
	# Иначе русло может заходить на сухой склон на стыке диагоналей.
	if not world.config.contains_point(point):
		return INF
	var cell: Vector2i = world.config.cell_at(point)
	var u := point.x - float(cell.x)
	var v := point.y - float(cell.y)
	return ShoreVisual.height(
		world.vertex_at(cell), world.vertex_at(cell + Vector2i.RIGHT),
		world.vertex_at(cell + Vector2i.DOWN),
		world.vertex_at(cell + Vector2i(1, 1)), u, v)


static func _river_bank(world: RefCounted, center: Vector2,
		target: Vector2, physical_level: float) -> Vector2:
	# Сначала оставляем полный поперечник, если грунт затоплен.
	# На сухом берегу двоичным поиском оставляем только мокрую
	# часть; обе стороны каждого речного звена рассчитываются
	# одинаково в мировых координатах, даже на стыке чанков.
	if _river_visual_ground(world, target) <= physical_level:
		return target
	if _river_visual_ground(world, center) > physical_level:
		return center
	var wet := 0.0
	var dry := 1.0
	for _step in range(12):
		var middle := (wet + dry) * 0.5
		if _river_visual_ground(world, center.lerp(target, middle)) <= physical_level:
			wet = middle
		else:
			dry = middle
	return center.lerp(target, wet)


static func _render_river(tool: SurfaceTool, world: RefCounted,
		hydro: RefCounted, cell: Vector2i, index: int,
		level: float, tint: Color, ice: float,
		fire: RefCounted = null, pristine_tint: Color = Color.WHITE) -> int:
	var start_frame := _river_frame(world, hydro, cell)
	var start: Vector2 = start_frame["center"]
	var direction_start: Vector2 = start_frame["direction"]
	var direction_end := direction_start
	var next: int = hydro.downstream_of(index)
	var finish := start + Vector2(0.0, 0.18)
	var end_level := level + WATER_OFFSET
	if next >= 0:
		var target: Vector2i = hydro.cell_from_index(next)
		var end_frame := _river_frame(world, hydro, target)
		finish = end_frame["center"]
		direction_end = end_frame["direction"]
		if hydro.has_water(next):
			end_level = hydro.level_at(next) + WATER_OFFSET
		else:
			end_level = world.height_at(finish) + 0.06
	var span: float = start.distance_to(finish)
	if span < 0.00001:
		return 0
	var control0 := start + direction_start * span * 0.35
	var control1 := finish - direction_end * span * 0.35
	var intensity := 0.0
	if next >= 0:
		var pressure: float = hydro.flow_pressure_at(index)
		intensity = clampf(0.35 + sqrt(maxf(0.0, pressure)) * 0.32, 0.35, 1.0)
	# У истока и конца соседнего руслового звена одинаковый
	# расход, поэтому обе независимо построенные кромки совпадут.
	var initial_width := _river_width(hydro.discharge_at_index(index))
	var final_width := initial_width
	if next >= 0 and hydro.river_at(next):
		final_width = _river_width(hydro.discharge_at_index(next))
	var segments := _river_segment_count(direction_start, direction_end)
	var last_dir := Vector2.ZERO
	var last := PackedVector3Array()
	var last_coverage := 1.0
	# Цвет следующего руслового звена читается из его фактической
	# взвеси; между центрами плавно смешиваем оба физических уровня.
	var end_tint := tint
	if fire != null and next >= 0 and hydro.has_water(next):
		end_tint = _ash_tint(pristine_tint,
			hydro.cell_from_index(next), fire, ice)
	var previous_tint := tint
	var terminal: bool = next < 0 or not hydro.has_water(next)
	for segment in range(segments + 1):
		var t := float(segment) / float(segments)
		var center := _river_curve(start, control0, control1, finish, t)
		var direction := _river_curve_direction(start, control0, control1, finish, t)
		var altitude := lerpf(level + WATER_OFFSET, end_level, t)
		var width := lerpf(initial_width, final_width, t)
		var section := _river_section(world, center, direction, altitude, width)
		var coverage := 1.0
		if start_frame["headwater"]:
			coverage *= smoothstep(0.0, 0.65, t)
		if terminal:
			coverage *= 1.0 - smoothstep(0.35, 1.0, t)
		if not last.is_empty():
			var flow := (last_dir + direction).normalized() * intensity
			if next < 0:
				flow = RIVER_WITHOUT_FLOW
			var current_tint: Color = tint.lerp(end_tint, t)
			_add_river_section(tool, last, section, previous_tint,
				current_tint, ice, flow, Vector2(last_coverage, coverage))
		last_coverage = coverage
		previous_tint = tint.lerp(end_tint, t)
		last = section
		last_dir = direction
	return segments * 4


static func _river_section(world: RefCounted, center: Vector2,
		direction: Vector2, altitude: float,
		physical_width: float = 0.30) -> PackedVector3Array:
	# Небольшой мировой изгиб оси удерживается внутри мокрой
	# поверхности. По тому же правилу соседние чанки получают
	# одинаковый центр и нормаль на общей речной вершине.
	var normal := Vector2(-direction.y, direction.x)
	var bend := sin(center.dot(Vector2(0.72, 0.43)))
	var shifted := center + normal * bend * 0.18
	var water_level := altitude - WATER_OFFSET
	if _river_visual_ground(world, shifted) <= water_level:
		center = shifted
	# Колебания ширины непрерывны по мировым координатам,
	# а основная ширина следует расходу настоящего водосбора.
	var width := clampf(physical_width +
		sin(center.dot(Vector2(0.70, -0.43))) * 0.035, 0.20, 0.58)
	var left := _river_bank(world, center, center - normal * width, water_level)
	var right := _river_bank(world, center, center + normal * width, water_level)
	return PackedVector3Array([
		world.config.to_scene(left, altitude),
		world.config.to_scene(center, altitude),
		world.config.to_scene(right, altitude),
	])


static func _add_river_section(tool: SurfaceTool, start: PackedVector3Array,
		finish: PackedVector3Array, tint: Color, end_tint: Color,
		ice: float, flow: Vector2, coverage: Vector2) -> void:
	# Цвет отдельной вершины следует концентрации у начала/конца
	# течения, не добавляя ни вершин, ни новой текстуры в шейдер.
	tool.set_normal(Vector3.UP)
	tool.set_uv2(flow)
	for half in range(2):
		for corner in [0, 1, 2, 0, 2, 3]:
			var across: int = half + int(corner == 1 or corner == 2)
			# Глубина уменьшается к берегам и на концах русла.
			var at_start: bool = corner < 2
			var depth := coverage.x if at_start else coverage.y
			tool.set_color(tint if at_start else end_tint)
			tool.set_uv(Vector2(depth if across == 1 else 0.0, ice))
			tool.add_vertex(start[across] if at_start else finish[across])


const FLOOD_COVERAGE_THRESHOLD := 0.45


static func _flood_source_coverage(hydro: RefCounted, index: int) -> float:
	# Затопленная пойма и озеро занимают полную физическую клетку
	# исходного интерполяционного поля. Обычное русло уже:
	# его поперечник определяется настоящим расходом воды.
	if not hydro.has_water(index):
		return 0.0
	if hydro.flooded_at(index) or hydro.lake_at(index):
		return 1.0
	if not hydro.river_at(index):
		return 0.0
	# Старые тестовые модели не обязаны содержать расход:
	# для них сохраняем прежний исходный профиль.
	if not hydro.has_method("discharge_at_index"):
		return 1.0
	var width := _river_width(hydro.discharge_at_index(index))
	# Билинейный профиль от центра реки убывает как (1 - расстояние).
	# Изолиния 0,45 должна проходить на расстоянии width:
	# вклад = порог / (1 - width). Это убирает внезапное
	# расширение тонкой ленты при переходе к залитой пойме.
	return clampf(FLOOD_COVERAGE_THRESHOLD / (1.0 - width), 0.0, 1.0)


static func _flood_profile(hydro: RefCounted, point: Vector2) -> Vector2:
	# Единое поле для соседних клеток, включая границы чанков.
	# X — визуальная доля покрытой водой территории, Y — уровень.
	var center_space := point - Vector2(0.5, 0.5)
	var cell := Vector2i(floori(center_space.x), floori(center_space.y))
	var u := center_space.x - floorf(center_space.x)
	var v := center_space.y - floorf(center_space.y)
	var coverage := 0.0
	var level_sum := 0.0
	var level_weight := 0.0
	for dy in range(2):
		for dx in range(2):
			var index: int = hydro.cell_index(cell + Vector2i(dx, dy))
			# Обычные реки задают узкий вход в пойму, а реально
			# затопленные клетки остаются полными. Одинаковое поле
			# мировой сетки используется на стыках всех чанков.
			var source := _flood_source_coverage(hydro, index)
			if source <= 0.0:
				continue
			var weight: float = (u if dx == 1 else 1.0 - u) * \
				(v if dy == 1 else 1.0 - v) * source
			coverage += weight
			# Уровень усредняем теми же весами, иначе при разных
			# уровнях реки и паводка получится ложный высокий клин.
			level_sum += hydro.level_at(index) * weight
			level_weight += weight

	if level_weight > 0.000001:
		return Vector2(clampf(coverage, 0.0, 1.0), level_sum / level_weight)

	# Даже сухие вершины должны получать гидрологический уровень,
	# иначе пересечение контура с сухой стороной опустится к нулю.
	var nearest := INF
	var nearest_level := 0.0
	for dy in range(-1, 3):
		for dx in range(-1, 3):
			var candidate := cell + Vector2i(dx, dy)
			var index: int = hydro.cell_index(candidate)
			if _flood_source_coverage(hydro, index) <= 0.0:
				continue
			var distance: float = (point - Vector2(candidate) -
				Vector2(0.5, 0.5)).length_squared()
			if distance < nearest:
				nearest = distance
				nearest_level = hydro.level_at(index)
	return Vector2(0.0, nearest_level)


static func _clip_flood_coverage(triangle: PackedVector4Array) -> PackedVector4Array:
	# Вектор: X/Y — мировые координаты, Z — уровень, W — покрытие.
	# Обрезка по общей изолинии исключает плитки и квадратные отверстия.
	var polygon := PackedVector4Array()
	var previous := triangle.size() - 1
	for current in range(triangle.size()):
		var a: Vector4 = triangle[previous]
		var b: Vector4 = triangle[current]
		var was_wet := a.w >= FLOOD_COVERAGE_THRESHOLD
		var is_wet := b.w >= FLOOD_COVERAGE_THRESHOLD
		if was_wet != is_wet:
			var t := clampf((FLOOD_COVERAGE_THRESHOLD - a.w) /
				(b.w - a.w), 0.0, 1.0)
			polygon.append(a.lerp(b, t))
		if is_wet:
			polygon.append(b)
		previous = current
	return polygon



static func _flood_clearance(vertex: Vector4, cell: Vector2i,
		heights: PackedFloat32Array) -> float:
	# Сравниваем именно физический уровень воды (Z), а не высоту
	# уже поднятого визуального меша. Высоту склона берём из той
	# же билинейной сетки, что используется в Chunk у берега.
	var u := clampf(vertex.x - float(cell.x), 0.0, 1.0)
	var v := clampf(vertex.y - float(cell.y), 0.0, 1.0)
	var terrain := ShoreVisual.height(
		heights[0], heights[1], heights[2], heights[3], u, v)
	return vertex.z - terrain


static func _clip_flood_to_ground(polygon: PackedVector4Array,
		cell: Vector2i, heights: PackedFloat32Array) -> PackedVector4Array:
	# Одной изолинии заполнения недостаточно: она заходила на
	# высокий сухой берег, после чего max(level, terrain) превращал
	# его в нарисованную бирюзовую воду. Второй контур оставляет
	# только точки, где физический уровень достигает грунта.
	# Общие рёбра соседних чанков используют одни физические
	# вершины и одинаковую линейную интерполяцию пересечения.
	var clipped := PackedVector4Array()
	if polygon.is_empty():
		return clipped
	var previous: Vector4 = polygon[polygon.size() - 1]
	var previous_depth := _flood_clearance(previous, cell, heights)
	for current in polygon:
		var depth := _flood_clearance(current, cell, heights)
		var previous_wet := previous_depth >= 0.0
		var current_wet := depth >= 0.0
		if previous_wet != current_wet:
			var fraction := clampf(previous_depth /
				(previous_depth - depth), 0.0, 1.0)
			# На диагонали билинейный склон может быть нелинейным.
			# Уточняем пересечение двоичным поиском, но на
			# горизонтальных и вертикальных рёбрах сохраняем
			# точную линейную точку для бесшовных соседей.
			if not is_equal_approx(previous.x, current.x) \
					and not is_equal_approx(previous.y, current.y):
				var low := 0.0
				var high := 1.0
				for _step in range(16):
					var middle := (low + high) * 0.5
					var middle_wet := _flood_clearance(
						previous.lerp(current, middle), cell, heights) >= 0.0
					if middle_wet == previous_wet:
						low = middle
					else:
						high = middle
				fraction = (low + high) * 0.5
			clipped.append(previous.lerp(current, fraction))
		if current_wet:
			clipped.append(current)
		previous = current
		previous_depth = depth
	return clipped


static func _flood_motion_at(hydro: RefCounted, point: Vector2) -> float:
	## Вычисляем только визуальную силу паводка из готовой гидрологии.
	## Никакой анимационный параметр не меняет уровень воды или сток.
	if hydro == null:
		return 0.0
	var center_space := point - Vector2(0.5, 0.5)
	var base := Vector2i(floori(center_space.x), floori(center_space.y))
	var u := center_space.x - floorf(center_space.x)
	var v := center_space.y - floorf(center_space.y)
	var result := 0.0
	for dy in range(2):
		for dx in range(2):
			var index: int = hydro.cell_index(base + Vector2i(dx, dy))
			if not hydro.flooded_at(index):
				continue
			# Соседние вершины и чанки читают одни и те же физические
			# клетки; степень турбулентности плавно убывает у сухого края.
			var weight: float = (u if dx == 1 else 1.0 - u) * \
				(v if dy == 1 else 1.0 - v)
			var depth: float = hydro.flood_depth_at(index)
			var pressure := 0.0
			# Старые тестовые реализации гидрологии знают глубину,
			# но не обязаны предоставлять величину расхода.
			if hydro.has_method("flow_pressure_at"):
				pressure = float(hydro.flow_pressure_at(index))
			var energy := clampf(depth * 0.55 +
				maxf(0.0, pressure - 0.55) * 0.28, 0.0, 1.0)
			result += energy * weight
	return clampf(result, 0.0, 1.0)


static func _add_flood_polygon(tool: SurfaceTool, world: RefCounted,
		cell: Vector2i, polygon: PackedVector4Array, heights: PackedFloat32Array,
		tint: Color, ice: float, hydro: RefCounted = null) -> int:
	# Сначала отсекаем сухой склон; прозрачность и небольшой
	# вертикальный WATER_OFFSET не могут изображать там воду.
	var submerged: PackedVector4Array = _clip_flood_to_ground(
		polygon, cell, heights)
	if submerged.size() < 3:
		return 0
	var added := 0
	tool.set_normal(Vector3.UP)
	for i in range(1, submerged.size() - 1):
		var a := Vector2(submerged[0].x, submerged[0].y)
		var b := Vector2(submerged[i].x, submerged[i].y)
		var c := Vector2(submerged[i + 1].x, submerged[i + 1].y)
		if absf((b - a).cross(c - a)) < 0.000001:
			continue
		for vertex in [submerged[0], submerged[i], submerged[i + 1]]:
			var u := clampf(vertex.x - float(cell.x), 0.0, 1.0)
			var v := clampf(vertex.y - float(cell.y), 0.0, 1.0)
			var terrain := ShoreVisual.height(
				heights[0], heights[1], heights[2], heights[3], u, v)
			# Тонкая паводковая плёнка не проваливается под визуальный грунт.
			# Это коррекция представления, не изменение физического уровня.
			var visible_level := maxf(vertex.z, terrain) + WATER_OFFSET
			var depth := maxf(0.0, vertex.z - terrain)
			var alpha := smoothstep(FLOOD_COVERAGE_THRESHOLD, 0.80, vertex.w)
			tool.set_color(Color(tint.r, tint.g, tint.b, tint.a * alpha))
			# W5: отрицательная метка отмечает пойму, а Y хранит
			# интенсивность только реального затопления по глубине/расходу.
			# Нулевой Y у сухой кромки не создаёт фиктивный паводок.
			var motion := _flood_motion_at(hydro, Vector2(vertex.x, vertex.y))
			tool.set_uv2(Vector2(FLOOD_MARKER_X, motion))
			tool.set_uv(Vector2(clampf(depth / SHORE_FADE_DEPTH, 0.0, 1.0), ice))
			tool.add_vertex(world.config.to_scene(
				Vector2(vertex.x, vertex.y), visible_level))
		added += 1
	return added


static func _flood_cell(tool: SurfaceTool, world: RefCounted,
		hydro: RefCounted, cell: Vector2i, tint: Color, ice: float,
		samples: Dictionary) -> int:
	# У каждой клетки нет своего контура. Вершины берутся из одного
	# глобального поля, поэтому между чанками нет прямоугольных швов.
	var heights := PackedFloat32Array([
		world.vertex_at(cell),
		world.vertex_at(cell + Vector2i(1, 0)),
		world.vertex_at(cell + Vector2i(0, 1)),
		world.vertex_at(cell + Vector2i(1, 1))
	])
	var grid := PackedVector4Array()
	for sy in range(SHORE_SUBDIVISIONS + 1):
		for sx in range(SHORE_SUBDIVISIONS + 1):
			var point := Vector2(cell) + Vector2(
				float(sx) / float(SHORE_SUBDIVISIONS),
				float(sy) / float(SHORE_SUBDIVISIONS))
			# Ключ в глобальной сетке одинаков для соседних клеток.
			var key := Vector2i(cell.x * SHORE_SUBDIVISIONS + sx,
				cell.y * SHORE_SUBDIVISIONS + sy)
			var profile: Vector2
			if samples.has(key):
				profile = samples[key]
			else:
				profile = _flood_profile(hydro, point)
				samples[key] = profile
			grid.append(Vector4(point.x, point.y, profile.y, profile.x))

	var added := 0
	for sy in range(SHORE_SUBDIVISIONS):
		for sx in range(SHORE_SUBDIVISIONS):
			var a := sy * (SHORE_SUBDIVISIONS + 1) + sx
			var b := a + 1
			var c := a + SHORE_SUBDIVISIONS + 1
			var d := c + 1
			for triangle in [
				PackedVector4Array([grid[a], grid[c], grid[b]]),
				PackedVector4Array([grid[d], grid[b], grid[c]])
			]:
				var polygon := _clip_flood_coverage(triangle)
				added += _add_flood_polygon(
					tool, world, cell, polygon, heights, tint, ice, hydro)
	return added


static func _flood_tint(ice: float) -> Color:
	# У связной поймы общий базовый цвет, независимо от того,
	# назвала ли гидрология исходную клетку рекой, озером или разливом.
	return Color(0.17, 0.34, 0.38, 0.90).lerp(
		Color(0.77, 0.86, 0.89, 0.96), ice)


static func create_mesh(world: RefCounted, hydro: RefCounted, chunk: Vector2i,
		surface: RefCounted = null, fire: RefCounted = null) -> ArrayMesh:
	hydro.ensure_ready()
	return mesh_from_arrays(prepare_arrays(world, hydro, chunk, surface, fire))


static func mesh_from_arrays(arrays: Array) -> ArrayMesh:
	var result := ArrayMesh.new()
	if not arrays.is_empty():
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result


static func _ash_tint(color: Color, cell: Vector2i,
		fire: RefCounted, ice: float) -> Color:
	# Мутность основана только на конечной взвеси FireRegistry.
	# Осевший ил не окрашивает воду; замёрзшая вода сохраняет лёд.
	if fire == null:
		return color
	var intensity: float = fire.ash_turbidity_at(cell) * (1.0 - ice)
	var amount := intensity * 0.72
	return color.lerp(Color(0.42, 0.34, 0.23, color.a), amount)


static func prepare_arrays(world: RefCounted, hydro: RefCounted, chunk: Vector2i,
		surface: RefCounted = null, fire: RefCounted = null,
		cancel_check: Callable = Callable()) -> Array:
	# Физические модели уже рассчитаны; строим только CPU-массивы.
	# Отмена не меняет воду, а возвращает пустой результат воркеру.
	if cancel_check.is_valid() and cancel_check.call():
		return []
	var bounds: Rect2i = world.config.chunk_rect(chunk)
	if not bounds.has_area():
		return []
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var added := 0
	var flood_samples := {}
	for y in range(bounds.position.y, bounds.end.y):
		# Долгие проходы по речным и паводковым клеткам прерываются
		# между строками при уходе камеры или смене поколения.
		if cancel_check.is_valid() and cancel_check.call():
			return []
		for x in range(bounds.position.x, bounds.end.x):
			var cell := Vector2i(x, y)
			var index: int = hydro.cell_index(cell)
			var physical_water: bool = hydro.has_water(index)
			var flood_near: bool = ShoreVisual.near_flood(hydro, cell)
			var context: Dictionary = ShoreVisual.water_context(world, hydro, cell)
			if not physical_water and context.is_empty() and not flood_near:
				continue
			var level: float = hydro.level_at(index) if physical_water else float(context.get("level", 0.0))
			var lake: bool = hydro.lake_at(index) if physical_water else bool(context.get("lake", false))
			var ocean: bool = hydro.ocean_at(index) if physical_water else bool(context.get("ocean", false))
			var river: bool = hydro.river_at(index) if physical_water else false
			var color := Color(0.16, 0.34, 0.38, 0.92)
			if ocean:
				color = Color(0.12, 0.27, 0.35, 0.93)
			elif lake:
				color = Color(0.14, 0.31, 0.37, 0.91)
			elif not river:
				color = Color(0.22, 0.37, 0.38, 0.83)
			var ice := 0.0
			if surface != null:
				var frost_index: int = int(context["index"]) if not context.is_empty() else index
				var frost: float = surface.frost_at_index(frost_index)
				ice = smoothstep(0.20, 0.90, frost)
				color = color.lerp(Color(0.77, 0.86, 0.89, 0.96), ice)
			# Настоящая взвесь подкрашивает уже существующий цвет
			# воды, не меняя уровней, русел, волн и природной физики.
			var pristine_tint := color
			color = _ash_tint(color, cell, fire, ice)
			if flood_near and not ocean:
				# Для затопленной поймы сохраняем физический контур,
				# окрашивая его только при действительном запасе золы.
				added += _flood_cell(tool, world, hydro, cell,
					_ash_tint(_flood_tint(ice), cell, fire, ice),
					ice, flood_samples)
				continue
			if ocean or lake:
				added += _water_cell(tool, world, cell, level, color, ice,
					STANDING_OCEAN if ocean else STANDING_LAKE)
				continue
			if not river:
				continue

			# Геометрия — плавная кривая, физический сток остаётся дискретным.
			# Непрерывное направление концов для соседних русловых звеньев.
			added += _render_river(tool, world, hydro, cell, index,
				level, color, ice, fire, pristine_tint)
	if added > 0:
		return tool.commit_to_arrays()
	return []
