extends RefCounted
## Отрисовка водной поверхности по действующим отметкам гидрологии.
## Прибрежные треугольники обрезаются по реальной геометрии грунта.

const ShoreVisual = preload("res://scripts/shore_visual.gd")
const WATER_OFFSET := 0.018
const SHORE_FADE_DEPTH := 0.7
# Только пересекающие сушу клетки получают более точную кромку.
const SHORE_SUBDIVISIONS := ShoreVisual.SUBDIVISIONS


static func _quad(tool: SurfaceTool, a: Vector3, b: Vector3,
		c: Vector3, d: Vector3, tint: Color, ice: float = 0.0) -> void:
	tool.set_color(tint)
	tool.set_normal(Vector3.UP)
	tool.set_uv(Vector2(1.0, ice))
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
		ice: float = 0.0) -> int:
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
			tool.set_uv(Vector2(vertex.z, ice))
			tool.add_vertex(world.config.to_scene(
				Vector2(vertex.x, vertex.y), level + WATER_OFFSET))
		added += 1
	return added


static func _water_cell(tool: SurfaceTool, world: RefCounted,
		cell: Vector2i, level: float, tint: Color, ice: float = 0.0) -> int:
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
			world.config.to_scene(Vector2(c), level + WATER_OFFSET), tint, ice)
		return 2

	# Высоты воды совпадают с уточнённой визуальной сеткой суши.
	# Делим только береговые полигоны: открытая вода не усложняется.
	# Соседние клетки получают одинаковые точки на общей границе.
	return _subdivided_shore(tool, world, cell, level, tint, ice,
		ha, hb, hc, hd)


static func _terrain_height(ha: float, hb: float, hc: float,
		hd: float, u: float, v: float) -> float:
	# Та же визуальная высота, что у береговых клеток Chunk.
	# Физические высоты WorldMap и водный баланс не изменяются.
	return ShoreVisual.height(ha, hb, hc, hd, u, v)

static func _subdivided_shore(tool: SurfaceTool, world: RefCounted,
		cell: Vector2i, level: float, tint: Color, ice: float,
		ha: float, hb: float, hc: float, hd: float) -> int:
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
			added += _add_polygon(tool, world, first, level, tint, ice)
			added += _add_polygon(tool, world, second, level, tint, ice)
	return added


const RIVER_SEGMENTS := 4


static func _river_direction(hydro: RefCounted, cell: Vector2i) -> Vector2:
	var index: int = hydro.cell_index(cell)
	if index < 0:
		return Vector2(0.0, 1.0)
	var downstream: int = hydro.downstream_of(index)
	var outgoing := Vector2.ZERO
	if downstream >= 0:
		var target: Vector2i = hydro.cell_from_index(downstream)
		outgoing = Vector2(target - cell).normalized()
	var upstream := Vector2.ZERO
	var greatest := -1.0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var upstream_cell := cell + Vector2i(dx, dy)
			var candidate: int = hydro.cell_index(upstream_cell)
			if candidate < 0 or hydro.downstream_of(candidate) != index:
				continue
			var flow: float = hydro.discharge_at_index(candidate)
			if flow > greatest:
				greatest = flow
				upstream = Vector2(cell - upstream_cell).normalized()
	if outgoing == Vector2.ZERO:
		return upstream if upstream != Vector2.ZERO else Vector2(0.0, 1.0)
	if upstream == Vector2.ZERO:
		return outgoing
	var average := upstream + outgoing
	return average.normalized() if average.length_squared() > 0.0001 else outgoing


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
		level: float, tint: Color, ice: float) -> int:
	var start := Vector2(cell) + Vector2(0.5, 0.5)
	var next: int = hydro.downstream_of(index)
	var finish := start + Vector2(0.0, 0.18)
	var end_level := level + WATER_OFFSET
	if next >= 0:
		var target: Vector2i = hydro.cell_from_index(next)
		finish = Vector2(target) + Vector2(0.5, 0.5)
		if hydro.has_water(next):
			end_level = hydro.level_at(next) + WATER_OFFSET
		else:
			end_level = world.height_at(finish) + 0.06
	var span: float = start.distance_to(finish)
	if span < 0.00001:
		return 0
	var direction_start := _river_direction(hydro, cell)
	var direction_end := direction_start
	if next >= 0:
		direction_end = _river_direction(hydro, hydro.cell_from_index(next))
	var control0 := start + direction_start * span * 0.35
	var control1 := finish - direction_end * span * 0.35
	var last_dir := _river_curve_direction(start, control0, control1, finish, 0.0)
	var last_side := Vector2(-last_dir.y, last_dir.x) * 0.24
	var last_center := start
	var last_level := level + WATER_OFFSET
	for segment in range(1, RIVER_SEGMENTS + 1):
		var t := float(segment) / float(RIVER_SEGMENTS)
		var center := _river_curve(start, control0, control1, finish, t)
		var direction := _river_curve_direction(start, control0, control1, finish, t)
		var side := Vector2(-direction.y, direction.x) * 0.24
		var altitude := lerpf(level + WATER_OFFSET, end_level, t)
		_quad(tool, world.config.to_scene(last_center - last_side, last_level),
			world.config.to_scene(last_center + last_side, last_level),
			world.config.to_scene(center + side, altitude),
			world.config.to_scene(center - side, altitude), tint, ice)
		last_center = center
		last_side = side
		last_level = altitude
	return RIVER_SEGMENTS * 2


static func create_mesh(world: RefCounted, hydro: RefCounted, chunk: Vector2i,
		surface: RefCounted = null) -> ArrayMesh:
	hydro.ensure_ready()
	var bounds: Rect2i = world.config.chunk_rect(chunk)
	var result := ArrayMesh.new()
	if not bounds.has_area():
		return result
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var added := 0
	for y in range(bounds.position.y, bounds.end.y):
		for x in range(bounds.position.x, bounds.end.x):
			var cell := Vector2i(x, y)
			var index: int = hydro.cell_index(cell)
			var physical_water: bool = hydro.has_water(index)
			var context: Dictionary = ShoreVisual.water_context(world, hydro, cell)
			if not physical_water and context.is_empty():
				continue
			var level: float = hydro.level_at(index) if physical_water else float(context["level"])
			var lake: bool = hydro.lake_at(index) if physical_water else bool(context["lake"])
			var ocean: bool = hydro.ocean_at(index) if physical_water else bool(context["ocean"])
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
			if ocean or lake or not river:
				added += _water_cell(tool, world, cell, level, color, ice)
				continue

			# Геометрия — плавная кривая, физический сток остаётся дискретным.
			# Непрерывное направление концов для соседних русловых звеньев.
			added += _render_river(tool, world, hydro, cell, index,
				level, color, ice)
	if added > 0:
		tool.commit(result)
	return result
