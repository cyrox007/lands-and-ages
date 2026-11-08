extends SceneTree
## 9.4/#96: паводковая вода не покрывает сухую высокую землю.
## Проверяем изоляцию дефекта, общий берег двух чанков и физический мир.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Water = preload("res://scripts/water_mesh.gd")
const Shore = preload("res://scripts/shore_visual.gd")

class ControlledFlood:
	extends RefCounted
	## Контрольный водосбор расположен поперёк границы чанков.
	## Его уровень неизменен; форма поверхности задаётся WorldMap.
	const WIDTH := 32
	const HEIGHT := 16
	const LEVEL := 0.5
	var enabled := true

	func cell_index(cell: Vector2i) -> int:
		# Отрицательная координата не превращается в соседний
		# источник воды при пробах за пределами физической карты.
		if cell.x < 0 or cell.y < 0 or cell.x >= WIDTH or cell.y >= HEIGHT:
			return -1
		return cell.y * WIDTH + cell.x

	func ensure_ready() -> void:
		# Тестовая гидрология уже имеет вычисленный уровень воды.
		pass

	func flooded_at(index: int) -> bool:
		# Связный разлив пересекает x=16 — границу двух чанков.
		# По окончании дождя он исчезает без остаточного меша.
		if not enabled or index < 0:
			return false
		var x: int = index % WIDTH
		var y: int = int(index / WIDTH)
		return x >= 14 and x <= 17 and y >= 4 and y <= 11

	func has_water(index: int) -> bool:
		# Отдельного декоративного слоя воды нет: каждая
		# физически мокрая клетка — часть одного разлива.
		return flooded_at(index)

	func lake_at(_index: int) -> bool:
		# Не превращаем паводковые клетки в озёра.
		return false

	func ocean_at(_index: int) -> bool:
		# Морской уровень здесь намеренно отсутствует.
		return false

	func river_at(_index: int) -> bool:
		# Узкое русло отдельно проверяется водным W2-smoke.
		return false

	func level_at(index: int) -> float:
		# Даже возле сухого склона физический уровень не растёт
		# вслед за высотой земли: это ключ к регрессии.
		return LEVEL if has_water(index) else NAN

	func flood_depth_at(index: int) -> float:
		# Ограниченная глубина нужна только для визуальной
		# турбулентности; геометрия определяется уровнем.
		return 0.4 if flooded_at(index) else 0.0

	func flow_pressure_at(index: int) -> float:
		# Давление не меняет отметки реальной воды.
		return 1.0 if flooded_at(index) else 0.0


var failures: Array[String] = []


func _check(value: bool, message: String) -> void:
	# Проверяем каждое нарушение, чтобы сбой одного берега
	# не скрывал несовпадения на стыке соседних чанков.
	if not value:
		failures.append(message)


func _test_dry_slope() -> void:
	# В исходном алгоритме покрытие=100% при уровне 0.5 и
	# высоте грунта 2.0 рисовало бирюзовый полигон на высоте
	# 2.018. После исправления в сухом месте нет треугольников.
	var world := Map.new(Config.new(16, 16, 1729, 16, 16))
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var dry := PackedVector4Array([
		Vector4(5.0, 5.0, 0.5, 1.0),
		Vector4(6.0, 5.0, 0.5, 1.0),
		Vector4(6.0, 6.0, 0.5, 1.0),
		Vector4(5.0, 6.0, 0.5, 1.0)
	])
	var high_ground := PackedFloat32Array([2.0, 2.0, 2.0, 2.0])
	_check(Water._add_flood_polygon(tool, world, Vector2i(5, 5),
		dry, high_ground, Color.BLUE, 0.0) == 0,
		"Паводок не приподнимается над полностью сухим берегом")

	# Если только половина клетки ниже уровня 0.5,
	# сохраняется настоящая подводная часть без сухой плитки.
	var shore_ground := PackedFloat32Array([-1.0, 1.0, -1.0, 1.0])
	var wet_tool := SurfaceTool.new()
	wet_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var triangles: int = Water._add_flood_polygon(wet_tool, world,
		Vector2i(5, 5), dry, shore_ground, Color.BLUE, 0.0)
	_check(triangles > 0,
		"Отсечение не убило реально затопленную половину берега")
	if triangles > 0:
		var arrays: Array = wet_tool.commit_to_arrays()
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for point in positions:
			_check(point.x <= 5.751,
				"Бирюзовая плёнка не выходит на сухой подъём")
			_check(absf(point.y - (0.5 + Water.WATER_OFFSET)) < 0.002,
				"Вода остаётся на физическом уровне, не на вершине суши")


func _plane_world() -> RefCounted:
	# Наклон через x=16 создаём в настоящем WorldMap, не в
	# шейдере: слева уровень 0.5 покрывает землю, справа нет.
	var world := Map.new(Config.new(32, 16, 1729, 16, 16))
	var heights := {}
	for y in range(17):
		for x in range(33):
			heights[Vector2i(x, y)] = float(x - 16) * 0.35 \
				+ float(y - 8) * 0.025
	_check(world.apply_vertex_changes(heights),
		"Создана настоящая наклонная физическая поверхность")
	return world


func _edge_samples(arrays: Array, edge_x: float) -> Dictionary:
	# Убираем дубли одного треугольника и оставляем только
	# настоящие вершины поймы на общей границе x=16.
	var found := {}
	if arrays.is_empty():
		return found
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var labels: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	for i in range(positions.size()):
		if absf(positions[i].x - edge_x) > 0.00005 \
				or absf(labels[i].x - Water.FLOOD_MARKER_X) > 0.00005:
			continue
		var point := positions[i]
		var key := Vector2i(roundi(point.z * 10000.0),
			roundi(point.y * 10000.0))
		found[key] = true
	return found


func _test_chunk_boundary() -> void:
	# Граница строится двумя независимыми CPU-вызовами.
	# Приближение к воде должно совпасть по обе стороны, даже
	# если справа высокий сухой грунт и часть поймы обрезана.
	var world: RefCounted = _plane_world()
	var hydro := ControlledFlood.new()
	var before: Dictionary = world.to_data()
	var left: Array = Water.prepare_arrays(world, hydro, Vector2i(0, 0))
	var right: Array = Water.prepare_arrays(world, hydro, Vector2i(1, 0))
	_check(not left.is_empty() and not right.is_empty(),
		"Реальный слой поймы построен по обе стороны границы чанков")
	if left.is_empty() or right.is_empty():
		return
	var seam_a: Dictionary = _edge_samples(left, 16.0)
	var seam_b: Dictionary = _edge_samples(right, 16.0)
	_check(not seam_a.is_empty() and seam_a == seam_b,
		"На x=16 одинаковая водная кромка без дыр и скачка высоты")
	var water_vertices := 0
	for array in [left, right]:
		var vertices: PackedVector3Array = array[Mesh.ARRAY_VERTEX]
		var markers: PackedVector2Array = array[Mesh.ARRAY_TEX_UV2]
		var uvs: PackedVector2Array = array[Mesh.ARRAY_TEX_UV]
		_check(vertices.size() == markers.size()
			and vertices.size() == uvs.size(),
			"Паводковые вершины имеют полный набор атрибутов")
		for i in range(vertices.size()):
			if absf(markers[i].x - Water.FLOOD_MARKER_X) > 0.00005:
				continue
			water_vertices += 1
			var point: Vector3 = vertices[i]
			var map_point := Vector2(point.x, point.z)
			var cell := Vector2i(clampi(floori(map_point.x), 0, 31),
				clampi(floori(map_point.y), 0, 15))
			var u := clampf(map_point.x - float(cell.x), 0.0, 1.0)
			var v := clampf(map_point.y - float(cell.y), 0.0, 1.0)
			var terrain := Shore.height(
				world.vertex_at(cell),
				world.vertex_at(cell + Vector2i(1, 0)),
				world.vertex_at(cell + Vector2i(0, 1)),
				world.vertex_at(cell + Vector2i(1, 1)), u, v)
			_check(point.y <= ControlledFlood.LEVEL + Water.WATER_OFFSET + 0.001,
				"Вода на крутом сухом склоне не поднята над уровнем разлива")
			_check(point.y >= terrain + Water.WATER_OFFSET - 0.001,
				"Пойма не оказалась под грунтом при пересечении")
			_check(uvs[i].x >= 0.0 and uvs[i].x <= 1.0,
				"Глубина в UV находится в допустимом диапазоне")
	_check(water_vertices > 50,
		"Проверена непрерывная непустая пойма, а не пустой меш")
	_check(world.to_data() == before,
		"Клиппинг не изменил высоту мира или физические ревизии")
	# При спадании настоящего паводка очищается графика обоих
	# чанков. Ни одна отдельная визуальная лужа не сохраняется.
	hydro.enabled = false
	_check(Water.prepare_arrays(world, hydro, Vector2i(0, 0)).is_empty()
		and Water.prepare_arrays(world, hydro, Vector2i(1, 0)).is_empty(),
		"После спада физического разлива не осталось водных островков")


func _test_real_hydrology() -> void:
	# Проверяем не только синтетический перепад: реальная
	# гидрология создаёт паводок через дождь и рассчитывает
	# физические уровни из настоящей котловины.
	var world := Map.new(Config.new(12, 12, 9123))
	var heights := {}
	for y in range(13):
		for x in range(13):
			heights[Vector2i(x, y)] = -1.0 if x >= 4 and x <= 8 \
				and y >= 4 and y <= 8 else 2.0
	_check(world.apply_vertex_changes(heights),
		"Настоящая дождевая котловина создана")
	var hydro := Hydro.new(world)
	hydro.rebuild()
	_check(hydro.set_rainfall(2.2),
		"Уровни воды перерассчитаны реальным дождём")
	_check(int(hydro.water_count()["flooded"]) > 0,
		"В гидрологии реально появились затопленные клетки")
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var world_before: Dictionary = world.to_data()
	var surface_before: Dictionary = surface.to_snapshot()
	# Малый контрольный водосбор не обязан иметь все упакованные
	# слои полного WorldSave. Сверяем публичное состояние каждой
	# реальной гидрологической клетки без пустых base64-массивов.
	var hydro_before: Array[Dictionary] = []
	for y in range(12):
		for x in range(12):
			hydro_before.append(hydro.water_at(Vector2i(x, y)))
	var arrays: Array = Water.prepare_arrays(world, hydro,
		Vector2i(0, 0), surface)
	_check(not arrays.is_empty(),
		"После отсечения сухого грунта настоящая пойма сохранилась")
	var hydro_after: Array[Dictionary] = []
	for y in range(12):
		for x in range(12):
			hydro_after.append(hydro.water_at(Vector2i(x, y)))
	_check(world.to_data() == world_before
		and hydro_after == hydro_before
		and surface.to_snapshot() == surface_before,
		"Водная визуализация не изменяет WorldMap, Hydrology и Surface")


func _initialize() -> void:
	# Это машинная регрессия 9.4/#96, не художественный допуск.
	_test_dry_slope()
	_test_chunk_boundary()
	_test_real_hydrology()
	if not failures.is_empty():
		for failure in failures.slice(0, 20):
			push_error("9.4/#96/вода: " + failure)
		quit(1)
		return
	print("9.4/#96: сухой склон, общий шов и реальный паводок — успешно")
	quit(0)
