extends SceneTree
## Этап 11.6/W2: анимация речных струй соответствует физическому downstream.
## Графика не создаёт сток, массу воды или новый гидрологический уровень.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Water = preload("res://scripts/water_mesh.gd")
const WaterShader = preload("res://shaders/natural_water.gdshader")

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	## Собираем ошибки всех условий перед остановкой CI.
	if not ok:
		failures.append(reason)


func _test_river(world: RefCounted, hydro: RefCounted) -> void:
	## Ищем настоящую русловую клетку с известным downstream,
	## а не создаём виртуальное течение на случайной сухой клетке.
	var river := Vector2i(-1, -1)
	var index := -1
	for y in range(world.config.height):
		for x in range(world.config.width):
			var candidate := Vector2i(x, y)
			var i: int = hydro.cell_index(candidate)
			if hydro.river_at(i) and hydro.downstream_of(i) >= 0:
				river = candidate
				index = i
				break
		if index >= 0:
			break
	_check(index >= 0, "На тестовой карте существует реальная река")
	if index < 0:
		return

	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var triangles: int = Water._render_river(tool, world, hydro,
		river, index, hydro.level_at(index), Color(0.2, 0.4, 0.5), 0.0)
	var arrays: Array = tool.commit_to_arrays()
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var directions: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var ice: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	_check(triangles > 0 and positions.size() == triangles * 3,
		"Реальный речной меш содержит все треугольники поперечника")
	_check(directions.size() == positions.size(),
		"Каждая вершина русла получила направленный поток UV2")
	_check(ice.size() == positions.size() and ice[0].y == 0.0,
		"Ледяной параметр UV не смешивается с направлением течения")

	_check(ice.has(Vector2(-1.0, 0.0)) and ice.has(Vector2(-2.0, 0.0)),
		"У русла раздельно размечены края и середина для плавных берегов")
	var downstream: Vector2 = Vector2(
		hydro.cell_from_index(hydro.downstream_of(index)) - river).normalized()
	var min_forward := 1.0
	for item in directions:
		# Обязательная направленность, без движения против стока;
		# абсолютную скорость физическая модель пока не рассчитывает.
		var direction: Vector2 = item
		min_forward = minf(min_forward, direction.dot(downstream))
	_check(min_forward > 0.02,
		"Направление речной анимации связано с настоящим downstream")
	print("W2: русло ", river, ", минимальная проекция потока ",
		snappedf(min_forward, 0.001), ", треугольников ", triangles)

	var still := SurfaceTool.new()
	still.begin(Mesh.PRIMITIVE_TRIANGLES)
	Water._quad(still, Vector3.ZERO, Vector3.RIGHT,
		Vector3(1.0, 0.0, 1.0), Vector3.FORWARD,
		Color(0.2, 0.4, 0.5))
	var still_arrays: Array = still.commit_to_arrays()
	var still_flows: PackedVector2Array = still_arrays[Mesh.ARRAY_TEX_UV2]
	_check(still_flows.size() == 6,
		"У открытой воды также есть заполненный канал UV2")
	for value in still_flows:
		_check(value == Vector2.ZERO,
			"Море и озеро не получают фиктивное речное направление")


func _run() -> void:
	## Сначала строим настоящую гидрологию, затем сравниваем снимки.
	var world := Map.new(Config.new(128, 96, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())
	var moved := 0
	for y in range(world.config.height):
		for x in range(world.config.width):
			var cell := Vector2i(x, y)
			var index: int = hydro.cell_index(cell)
			if not hydro.river_at(index):
				continue
			var frame: Dictionary = Water._river_frame(world, hydro, cell)
			var anchor: Vector2 = frame["center"]
			var offset := anchor.distance_to(Vector2(cell) + Vector2(0.5, 0.5))
			if offset > 0.0001:
				moved += 1
				_check(offset < 0.221 and world.height_at(anchor) <= hydro.level_at(index),
					"Сглаживание удерживает ось внутри мокрой клетки")
	_check(moved > 0, "На ступенчатых поворотах ось русла сглажена")
	var world_before: Dictionary = world.to_data()
	var hydro_before: Dictionary = hydro.to_snapshot()
	var surface_before: Dictionary = surface.to_snapshot()
	_test_river(world, hydro)
	var code: String = WaterShader.code
	_check(code.contains("UV2") and code.contains("river_phase")
		and code.contains("river_highlight") and code.contains("wave_time"),
		"Водный PBR анимирует физическое направление течения")
	_check(not code.contains("VERTEX ="),
		"Волны не изменяют физический уровень и объём воды")
	_check(world.to_data() == world_before
		and hydro.to_snapshot() == hydro_before
		and surface.to_snapshot() == surface_before,
		"Визуальный сток не изменяет природный мир")

	if failures.is_empty():
		print("Этап 11.6/W2: речное течение по физическому стоку — успешно")
		quit(0)
		return
	for reason in failures:
		printerr("Этап 11.6/W2: ", reason)
	quit(1)


func _initialize() -> void:
	## Внешняя сцена и дорогая GPU-симуляция для проверки не нужны.
	_run()
