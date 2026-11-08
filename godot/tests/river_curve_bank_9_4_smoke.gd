extends SceneTree
## 9.4/#96: реальная река имеет гладкие повороты и мокрые берега.
## Два чанка не расходятся при изменении расхода и уровня воды.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Water = preload("res://scripts/water_mesh.gd")

class RiverRoute:
	extends RefCounted
	## Контрольный путь: прямая пересекает x=16, затем поворот.
	const WIDTH := 32
	const HEIGHT := 16
	const LEVEL := 0.8
	var route: Array[Vector2i] = []
	var downstream: Dictionary = {}
	var discharges: Dictionary = {}

	func _init() -> void:
		# Один непрерывный граф без декоративной воды. Расход
		# постепенно возрастает вниз по настоящему маршруту.
		for x in range(12, 19):
			route.append(Vector2i(x, 7))
		for cell in [Vector2i(18, 8), Vector2i(18, 9),
				Vector2i(19, 9)]:
			route.append(cell)
		for i in range(route.size()):
			var index := cell_index(route[i])
			downstream[index] = cell_index(route[i + 1]) \
				if i + 1 < route.size() else -1
			discharges[index] = 180.0 + float(i) * 170.0

	func ensure_ready() -> void:
		# Тестовый речной граф полностью рассчитан при создании.
		pass

	func cell_index(cell: Vector2i) -> int:
		# Запрос за пределами мира не превращаем в чужую воду.
		if cell.x < 0 or cell.y < 0 or cell.x >= WIDTH or cell.y >= HEIGHT:
			return -1
		return cell.y * WIDTH + cell.x

	func cell_from_index(index: int) -> Vector2i:
		# Преобразуем индекс обратно только при наличии ячейки.
		if index < 0 or index >= WIDTH * HEIGHT:
			return Vector2i(-1, -1)
		return Vector2i(index % WIDTH, int(index / WIDTH))

	func has_water(index: int) -> bool:
		# Вода есть исключительно на реальных звеньях пути.
		return discharges.has(index)

	func river_at(index: int) -> bool:
		# Не подменяем речной меш озером или морской плиткой.
		return has_water(index)

	func lake_at(_index: int) -> bool:
		# Озёр на заданном маршруте нет.
		return false

	func ocean_at(_index: int) -> bool:
		# Морского уровня в контролируемой модели нет.
		return false

	func flooded_at(_index: int) -> bool:
		# Геометрия проверяется без отдельной поймы.
		return false

	func level_at(index: int) -> float:
		# Все стыки намеренно получают один физический уровень.
		return LEVEL if has_water(index) else NAN

	func downstream_of(index: int) -> int:
		# Последнее звено имеет настоящий конец стока.
		return int(downstream.get(index, -1))

	func discharge_at_index(index: int) -> float:
		# Ширина должна учитывать этот конечный физический расход.
		return float(discharges.get(index, 0.0))

	func flow_pressure_at(index: int) -> float:
		# Рисунок волн не создаёт дополнительного течения.
		return 1.0 if has_water(index) else 0.0


var failures: Array[String] = []


func _check(condition: bool, reason: String) -> void:
	# Запоминаем нарушения отдельно: стык, физика и форма русла
	# должны иметь независимые признаки прохождения.
	if not condition:
		failures.append(reason)


func _flat_world() -> RefCounted:
	# На плоской мокрой подложке геометрия реки не может
	# маскировать треугольные ошибки сухим перекрытием.
	var world := WorldMap.new(Config.new(32, 16, 1729, 16, 16))
	var heights := {}
	for y in range(17):
		for x in range(33):
			heights[Vector2i(x, y)] = -1.0
	_check(world.apply_vertex_changes(heights),
		"Настоящий WorldMap получил физическое плоское дно")
	return world


func _contains_vertex(arrays: Array, point: Vector3) -> bool:
	# Проверяем фактические вершины Godot-меша, а не только
	# математическое совпадение двух рамок на бумаге.
	if arrays.is_empty():
		return false
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for vertex in vertices:
		if vertex.distance_to(point) < 0.00008:
			return true
	return false


func _test_route_and_seam() -> void:
	# Строим каждый чанк независимо — как при перемещении камеры.
	# Изгиб и физическая ширина у x=16 должны совпадать на обоих.
	var world: RefCounted = _flat_world()
	var hydro := RiverRoute.new()
	var map_before: Dictionary = world.to_data()
	var route_before: Dictionary = hydro.downstream.duplicate(true)
	var left: Array = Water.prepare_arrays(world, hydro, Vector2i.ZERO)
	var right: Array = Water.prepare_arrays(world, hydro, Vector2i(1, 0))
	_check(not left.is_empty() and not right.is_empty(),
		"Речные меши построены независимо по обе стороны x=16")
	if left.is_empty() or right.is_empty():
		return

	var joint := Vector2i(16, 7)
	var index: int = hydro.cell_index(joint)
	var frame: Dictionary = Water._river_frame(world, hydro, joint)
	var width: float = Water._river_width(hydro.discharge_at_index(index))
	var section: PackedVector3Array = Water._river_section(world,
		frame["center"], frame["direction"], RiverRoute.LEVEL
		+ Water.WATER_OFFSET, width)
	for vertex in section:
		_check(_contains_vertex(left, vertex) and
			_contains_vertex(right, vertex),
			"Одинаковое живое русло на стыке двух CPU-чанков")

	# Прямая не требует лишних сегментов, но поворот на 90°
	# должен иметь удвоенную точность дуги и сохранённый UV2.
	var straight := Vector2i(14, 7)
	var bend := Vector2i(17, 7)
	var samples := [
		{"cell": straight, "segments": Water.RIVER_SEGMENTS},
		{"cell": bend, "segments": Water.RIVER_BEND_SEGMENTS}
	]
	for sample in samples:
		var cell: Vector2i = sample["cell"]
		var cell_index: int = hydro.cell_index(cell)
		var tool := SurfaceTool.new()
		tool.begin(Mesh.PRIMITIVE_TRIANGLES)
		var triangles: int = Water._render_river(tool, world, hydro,
			cell, cell_index, hydro.level_at(cell_index),
			Color(0.16, 0.34, 0.38), 0.0)
		_check(triangles == int(sample["segments"]) * 4,
			"Точность реальной кривой зависит от поворота: " + str(cell))
		var mesh: Array = tool.commit_to_arrays()
		var positions: PackedVector3Array = mesh[Mesh.ARRAY_VERTEX]
		var directions: PackedVector2Array = mesh[Mesh.ARRAY_TEX_UV2]
		_check(positions.size() == triangles * 3
			and positions.size() == directions.size(),
			"Речной GL-меш сохраняет треугольники и UV2")
		for flow in directions:
			_check(flow.length() > 0.0 and flow.length() <= 1.001,
				"В новом речном поперечнике остаётся настоящий поток")

	_check(Water._river_width(1620.0) >
		Water._river_width(180.0) + 0.17,
		"Ширина зависит от настоящего расхода, а не фиксированных пикселей")
	_check(Water._river_width(1000000.0) <= 0.551,
		"Разлив не может бесконечно расширять речную ленту")
	_check(world.to_data() == map_before and hydro.downstream == route_before,
		"Построение кривой не изменяет рельеф и физический сток")


func _test_dry_bank() -> void:
	# Высокий грунт справа пересекает ширину реки. Раньше
	# поперечник всегда рисовался целиком поверх сухого склона.
	var world := WorldMap.new(Config.new(16, 16, 1729, 16, 16))
	var heights := {}
	for y in range(17):
		for x in range(17):
			heights[Vector2i(x, y)] = float(x - 7)
	_check(world.apply_vertex_changes(heights),
		"Создан реальный склон для пересечения речного берега")
	var level := 0.55
	var section: PackedVector3Array = Water._river_section(
		world, Vector2(7.38, 8.5), Vector2.DOWN,
		level + Water.WATER_OFFSET, 0.45)
	_check(section.size() == 3,
		"На сухом берегу сохранились оба края и ось русла")
	if section.size() != 3:
		return
	for vertex in section:
		var ground: float = Water._river_visual_ground(world,
			Vector2(vertex.x, vertex.z))
		_check(ground <= level + 0.001,
			"Ни одна вершина реки не поднята над сухим грунтом")
		_check(absf(vertex.y - level - Water.WATER_OFFSET) < 0.0001,
			"Графика не изменила физический уровень водной поверхности")
	var widths := Vector2(section[0].x, section[0].z).distance_to(
		Vector2(section[1].x, section[1].z))
	var other := Vector2(section[2].x, section[2].z).distance_to(
		Vector2(section[1].x, section[1].z))
	_check(minf(widths, other) < 0.35 and maxf(widths, other) > 0.35,
		"Сухая сторона обрезана, мокрый берег сохранил ширину")


func _test_real_hydrology() -> void:
	# Контрольный граф не подменяет настоящую гидрологию:
	# строим действующую карту и ищем несколько реальных русел.
	var world := WorldMap.new(Config.new(128, 96, 1729, 16, 32))
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())
	var world_before: Dictionary = world.to_data()
	var hydro_before: Dictionary = hydro.to_snapshot()
	var surface_before: Dictionary = surface.to_snapshot()
	var tested := 0
	var bends := 0
	for y in range(world.config.height):
		if tested >= 32:
			break
		for x in range(world.config.width):
			var cell := Vector2i(x, y)
			var index: int = hydro.cell_index(cell)
			var next: int = hydro.downstream_of(index)
			if not hydro.river_at(index) or next < 0:
				continue
			var frame: Dictionary = Water._river_frame(world, hydro, cell)
			var target: Dictionary = Water._river_frame(world, hydro,
				hydro.cell_from_index(next))
			var segments: int = Water._river_segment_count(
				frame["direction"], target["direction"])
			bends += int(segments > Water.RIVER_SEGMENTS)
			var tool := SurfaceTool.new()
			tool.begin(Mesh.PRIMITIVE_TRIANGLES)
			var tris: int = Water._render_river(tool, world, hydro,
				cell, index, hydro.level_at(index), Color.BLUE, 0.0)
			_check(tris == segments * 4,
				"Настоящее русло построено с точностью поворота")
			tested += 1
			if tested >= 32:
				break
	_check(tested >= 16 and bends > 0,
		"Проверены 16+ настоящих русел, включая изгибающиеся")
	_check(world.to_data() == world_before
		and hydro.to_snapshot() == hydro_before
		and surface.to_snapshot() == surface_before,
		"Речной рендер не изменяет действующие природные снимки")
	print("9.4/#96/реки: действительных звеньев=", tested,
		", кривых=", bends)


func _initialize() -> void:
	# Это техническая проверка CPU-мешей, а не оценка FPS
	# видеокарты или художественное утверждение речной графики.
	_test_route_and_seam()
	_test_dry_bank()
	_test_real_hydrology()
	if not failures.is_empty():
		for failure in failures.slice(0, 25):
			push_error("9.4/#96/реки: " + failure)
		quit(1)
		return
	print("9.4/#96: адаптивное русло, сухой берег и шов чанков — успешно")
	quit(0)
