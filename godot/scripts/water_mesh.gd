extends RefCounted
## Отрисовка водной поверхности по действующим отметкам гидрологии.
## Прибрежные треугольники обрезаются по реальной геометрии грунта.

const ShoreVisual = preload("res://scripts/shore_visual.gd")
const WATER_OFFSET := 0.018
const SHORE_FADE_DEPTH := 0.7
# Только пересекающие сушу клетки получают более точную кромку.
const SHORE_SUBDIVISIONS := ShoreVisual.SUBDIVISIONS
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
	var added := 0
	for j in range(SHORE_SUBDIVISIONS):
		for i in range(SHORE_SUBDIVISIONS):
			var u0 := float(i) / float(SHORE_SUBDIVISIONS)
			var u1 := float(i + 1) / float(SHORE_SUBDIVISIONS)
			var v0 := float(j) / float(SHORE_SUBDIVISIONS)
			var v1 := float(j + 1) / float(SHORE_SUBDIVISIONS)
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
	for segment in range(RIVER_SEGMENTS + 1):
		var t := float(segment) / float(RIVER_SEGMENTS)
		var center := _river_curve(start, control0, control1, finish, t)
		var direction := _river_curve_direction(start, control0, control1, finish, t)
		var altitude := lerpf(level + WATER_OFFSET, end_level, t)
		var section := _river_section(world, center, direction, altitude)
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
	return RIVER_SEGMENTS * 4


static func _river_section(world: RefCounted, center: Vector2,
		direction: Vector2, altitude: float) -> PackedVector3Array:
	# Одна и та же мировая фаза даёт общий поперечник на стыке звеньев.
	var normal := Vector2(-direction.y, direction.x)
	var bend := sin(center.dot(Vector2(0.34, 0.41)))
	var shifted := center + normal * bend * 0.22
	if world.height_at(shifted) <= altitude - WATER_OFFSET:
		center = shifted
	var width := 0.24 + sin(center.dot(Vector2(0.70, -0.43))) * 0.07
	var side := normal * width
	return PackedVector3Array([
		world.config.to_scene(center - side, altitude),
		world.config.to_scene(center, altitude),
		world.config.to_scene(center + side, altitude),
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
			if not hydro.has_water(index):
				continue
			# Реки соединяют соседние разливы; озёра/море рисуются отдельно.
			if not hydro.flooded_at(index) and \
					not hydro.river_at(index) and not hydro.lake_at(index):
				continue
			var weight: float = (u if dx == 1 else 1.0 - u) * \
				(v if dy == 1 else 1.0 - v)
			coverage += weight
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
			if not hydro.has_water(index):
				continue
			if not hydro.flooded_at(index) and \
					not hydro.river_at(index) and not hydro.lake_at(index):
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
	if polygon.size() < 3:
		return 0
	var added := 0
	tool.set_normal(Vector3.UP)
	for i in range(1, polygon.size() - 1):
		var a := Vector2(polygon[0].x, polygon[0].y)
		var b := Vector2(polygon[i].x, polygon[i].y)
		var c := Vector2(polygon[i + 1].x, polygon[i + 1].y)
		if absf((b - a).cross(c - a)) < 0.000001:
			continue
		for vertex in [polygon[0], polygon[i], polygon[i + 1]]:
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
		surface: RefCounted = null, fire: RefCounted = null) -> Array:
	# Models must already be ready; this isolated SurfaceTool only builds CPU arrays.
	var bounds: Rect2i = world.config.chunk_rect(chunk)
	if not bounds.has_area():
		return []
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var added := 0
	var flood_samples := {}
	for y in range(bounds.position.y, bounds.end.y):
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
