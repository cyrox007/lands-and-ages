extends SceneTree
## Этап 11.6/W3: ветровые волны озёр и моря привязаны к климату.
## Проверяем реальный меш, шейдер и отсутствие изменений физики мира.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const WeatherState = preload("res://scripts/weather_visual_state.gd")
const WeatherFX = preload("res://scripts/weather_fx_controller.gd")
const Water = preload("res://scripts/water_mesh.gd")
const WaterShader = preload("res://shaders/natural_water.gdshader")
const WorldScene = preload("res://scripts/world.gd")

var failures: Array[String] = []


func _check(condition: bool, message: String) -> void:
	## Не прерываем тест на первой ошибке: CI покажет все нарушенные условия.
	if not condition:
		failures.append(message)


func _check_water_marker(world: RefCounted, kind: Vector2,
		level: float, cell: Vector2i, label: String) -> void:
	## Строим тот же меш, что создаётся в игровом водном чанке.
	## Проверяем маркер на каждой вершине, в том числе у берега.
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var triangles: int = Water._water_cell(tool, world, cell, level,
		Color(0.12, 0.27, 0.35, 0.93), 0.0, kind)
	_check(triangles > 0, label + ": вода имеет треугольники")
	if triangles == 0:
		return
	var arrays: Array = tool.commit_to_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	_check(vertices.size() == triangles * 3 and uv2.size() == vertices.size(),
		label + ": метки UV2 согласованы с геометрией")
	for marker in uv2:
		_check(marker == kind, label + ": каждая вершина сохраняет тип водоёма")


func _check_water_mesh(world: RefCounted) -> void:
	## Открытую воду проверяем отдельно от обрезанного берегового полигона.
	var cell := Vector2i(10, 10)
	var maximum := -INF
	for dy in range(2):
		for dx in range(2):
			maximum = maxf(maximum, world.vertex_at(cell + Vector2i(dx, dy)))
	_check_water_marker(world, Water.STANDING_OCEAN, maximum + 2.0,
		cell, "Море")
	_check_water_marker(world, Water.STANDING_LAKE, maximum + 2.0,
		cell, "Озеро")

	# Находим реальный перепад, чтобы проверить обрезку по берегу.
	var shoreline_found := false
	for y in range(1, world.config.height - 2):
		if shoreline_found:
			break
		for x in range(1, world.config.width - 2):
			var corner := Vector2i(x, y)
			var low := INF
			var high := -INF
			for dy in range(2):
				for dx in range(2):
					var height: float = world.vertex_at(corner + Vector2i(dx, dy))
					low = minf(low, height)
					high = maxf(high, height)
			if high - low < 0.1:
				continue
			shoreline_found = true
			_check_water_marker(world, Water.STANDING_LAKE,
				lerpf(low, high, 0.5), corner, "Берег озера")
			break
	_check(shoreline_found, "На тестовой карте найден настоящий перепад берега")


func _check_climate_binding(climate: RefCounted, world: RefCounted) -> void:
	## Используем готовый снимок пяти климатических клеток, не генератор волн.
	var snapshot: Dictionary = WeatherState.sample(climate, world.config,
		Vector2(45.0, 35.0), 64.0)
	_check(float(snapshot["wind"]) > 0.0 and
		float(snapshot["wind"]) <= 1.0, "Ветер ограничен физическим климатом")
	_check(float(snapshot["storm"]) >= 0.0 and
		float(snapshot["storm"]) <= 1.0, "Шторм ограничен физическим климатом")

	# Вызываем настоящий метод сцены без запуска графического дерева.
	# Материал получает снимок, а физические модели не изменяются.
	var view := WorldScene.new()
	var fx := WeatherFX.new()
	view._water_material = ShaderMaterial.new()
	view._water_material.shader = WaterShader
	view._weather_fx = fx
	fx.apply_snapshot(snapshot, Vector2.ZERO, 0.0, 64.0,
		world.config.world_seed)
	view._sync_water_weather()
	_check(is_equal_approx(float(view._water_material.get_shader_parameter(
		"wind_strength")), float(snapshot["wind"])),
		"Шейдер получает реальную скорость ветра")
	_check(is_equal_approx(float(view._water_material.get_shader_parameter(
		"storm_strength")), float(snapshot["storm"])),
		"Шейдер получает реальную силу грозы")
	view.free()
	fx.free()


func _run() -> void:
	## Сравниваем физические снимки до и после проверки графики.
	var world := Map.new(Config.new(128, 96, 1729, 16, 32))
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	hydro.apply_rainfall_map(surface.runoff_map())
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	climate.set_day(17)
	var world_before: Dictionary = world.to_data()
	var hydro_before: Dictionary = hydro.to_snapshot()
	var surface_before: Dictionary = surface.to_snapshot()
	var climate_before: Dictionary = climate.to_data()

	_check_water_mesh(world)
	_check_climate_binding(climate, world)
	var code: String = WaterShader.code
	_check(code.contains("wind_strength") and code.contains("storm_strength")
		and code.contains("wind_phase") and code.contains("fwidth(wind_phase)"),
		"Шейдер имеет ветровые волны с фильтрацией дальних частот")
	_check(code.contains("river_strength") and code.contains("river_phase"),
		"Новый эффект сохраняет речное течение W2")
	_check(not code.contains("VERTEX ="),
		"Волны не перемещают физическую поверхность воды")
	_check(world.to_data() == world_before and
		hydro.to_snapshot() == hydro_before and
		surface.to_snapshot() == surface_before and
		climate.to_data() == climate_before,
		"Ветровая графика не изменяет климат, воду, грунт и рельеф")

	if failures.is_empty():
		print("Этап 11.6/W3: ветровые волны озёр и моря — успешно")
		quit(0)
		return
	for reason in failures:
		printerr("Этап 11.6/W3: ", reason)
	quit(1)


func _initialize() -> void:
	## Автономный запуск без сцены и рендеринга пригоден для CI.
	_run()
