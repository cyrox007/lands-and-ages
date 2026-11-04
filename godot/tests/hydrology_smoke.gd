extends SceneTree
## Приёмка гидрологии: сток к границе, отсутствие циклов, озёра и разливы.
## Без погодной симуляции, грунтов, растительности и объектов.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const WaterMesh = preload("res://scripts/water_mesh.gd")

var failures: Array[String] = []


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _initialize() -> void:
	_run()


func _topology(hydro: RefCounted, config: RefCounted) -> void:
	var outlet_total := 0.0
	var outlets := 0
	for y in range(config.height):
		for x in range(config.width):
			var cell := Vector2i(x, y)
			var data: Dictionary = hydro.water_at(cell)
			_check(data["spill"] >= data["ground"] - 0.0001, "Уровень заполнения не ниже грунта")
			var downstream: Vector2i = data["downstream"]
			if downstream == Vector2i(-1, -1):
				outlets += 1
				outlet_total += float(data["catchment"])
				_check(x == 0 or y == 0 or x == config.width - 1 or y == config.height - 1,
					"Выход бассейна только на границе")
				continue
			_check(abs(downstream.x - x) + abs(downstream.y - y) == 1,
				"Течение только в соседнюю клетку")
			var next: Dictionary = hydro.water_at(downstream)
			_check(int(next["order"]) < int(data["order"]), "Нет циклов, у приёмника меньший ранг")
			_check(float(next["spill"]) <= float(data["spill"]) + 0.0001,
				"Сток не идёт вверх по уровню заполнения")
			var out: Vector2i = data["outlet"]
			_check(out.x == 0 or out.y == 0 or out.x == config.width - 1
				or out.y == config.height - 1, "Каждый бассейн выходит на границу")
	_check(outlets > 0, "Существует хотя бы один выход")
	_check(absf(outlet_total - float(config.width * config.height)) < 0.2,
		"Суммарный сток по всем водосборам сохраняется")


func _run() -> void:
	# Сток проверяем на настоящем рельефе с неизменяемым seed.
	var world := WorldMap.new(Config.new(64, 48, 1729))
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	_topology(hydro, world.config)
	_check(hydro.water_at(Vector2i(-1, 0)).is_empty(), "Вода за пределами недоступна")
	_check(hydro.outlet_count() == 2 * (64 + 48) - 4,
		"Все клетки границы являются доступными выходами")
	var repeat := Hydrology.new(WorldMap.new(Config.new(64, 48, 1729)))
	repeat.rebuild()
	for pos in [Vector2i(1, 1), Vector2i(11, 13), Vector2i(30, 22), Vector2i(60, 45)]:
		_check(hydro.water_at(pos) == repeat.water_at(pos),
			"Повторный seed воспроизводит направления и водосборы")

	# При смене seed меняется естественный водосбор.
	var distinct := 0
	for world_seed in range(100, 200):
		var current_world := WorldMap.new(Config.new(18, 14, world_seed))
		var current := Hydrology.new(current_world)
		current.rebuild()
		var previous := Hydrology.new(WorldMap.new(Config.new(18, 14, world_seed)))
		previous.rebuild()
		var sample := Vector2i(9, 7)
		var a: Dictionary = current.water_at(sample)
		var b: Dictionary = previous.water_at(sample)
		_check(a == b, "Гидрология повторяется для seed %d" % world_seed)
		if current.water_at(Vector2i(10, 6))["spill"] != hydro.water_at(Vector2i(10, 6))["spill"]:
			distinct += 1
	_check(distinct > 90, "Проверены сто разных seed")

	# На полной испытательной карте проверяем присутствие рек и озёр.
	var large_world := WorldMap.new(Config.new())
	var large := Hydrology.new(large_world)
	large.rebuild()
	var totals: Dictionary = large.water_count()
	print("Гидрология 256×192: реки=%d, озёра=%d, разливы=%d" % [
		totals["rivers"], totals["lakes"], totals["flooded"]])
	_check(int(totals["rivers"]) > 0, "На полной карте есть речные участки")
	_check(int(totals["lakes"]) > 0, "На полной карте есть естественные озёра")
	for y in range(large_world.config.height):
		for x in range(large_world.config.width):
			var index := large.cell_index(Vector2i(x, y))
			if not large.river_at(index):
				continue
			var next := large.downstream_of(index)
			if next >= 0:
				_check(large.river_at(next) or large.ocean_at(next),
					"Река продолжается вниз по стоку или впадает в море")

	# Искусственная котловина: все вершины сперва на отметке 2.
	var bowl_world := WorldMap.new(Config.new(12, 12, 9123))
	var changes := {}
	for y in range(13):
		for x in range(13):
			changes[Vector2i(x, y)] = 2.0
	for y in range(4, 9):
		for x in range(4, 9):
			changes[Vector2i(x, y)] = -1.0
	_check(bowl_world.apply_vertex_changes(changes), "Создана искусственная котловина")
	var basin := Hydrology.new(bowl_world)
	basin.rebuild()
	_topology(basin, bowl_world.config)
	var lake := basin.water_at(Vector2i(5, 5))
	_check(bool(lake["lake"]), "Замкнутая котловина заполняется озером")
	_check(float(lake["spill"]) >= 1.99, "Уровень озера равен переливу через край")
	_check(float(lake["depth"]) >= 2.99, "Вода имеет физическую глубину")
	_check(not bool(basin.water_at(Vector2i(1, 1))["lake"]),
		"Сухая равнина не становится озером")
	var mesh := WaterMesh.create_mesh(bowl_world, basin, Vector2i(0, 0))
	_check(mesh.get_surface_count() > 0, "Водная поверхность создаёт GPU-меш")

	# Тестовый множитель осадков расширяет реки и может вызвать разлив.
	var before := basin.water_count()
	_check(basin.set_rainfall(2.2), "Интенсивность стока изменяется")
	var after := basin.water_count()
	_check(int(after["flooded"]) >= int(before["flooded"]), "Разлив не уменьшается от дождя")
	_check(int(after["flooded"]) > 0, "Повышение воды даёт локальное подтопление берегов")
	_check(float(basin.water_at(Vector2i(5, 5))["wetness"]) == 1.0,
		"Озеро даёт максимальную поверхностную влажность")
	_check(not basin.set_rainfall(-1.0), "Отрицательные осадки запрещены")
	_check(not basin.set_rainfall(INF), "Бесконечные осадки запрещены")
	var hydro_data: Dictionary = basin.to_data()
	var saved = JSON.parse_string(JSON.stringify(hydro_data))
	var reloaded := Hydrology.new(WorldMap.from_data(
		JSON.parse_string(JSON.stringify(bowl_world.to_data()))))
	_check(reloaded.load_data(saved), "Состояние гидрологии восстановлено")
	_check(is_equal_approx(reloaded.rainfall, basin.rainfall), "Множитель осадков сохранён")
	_check(reloaded.water_at(Vector2i(5, 5)) == basin.water_at(Vector2i(5, 5)),
		"Уровень озера восстановился по сохранённой геометрии")
	_check(not reloaded.load_data({"version": 22, "rainfall": 2.0}),
		"Неизвестный формат гидрологии отклоняется")

	# Изменение земли инвалидирует гидрологию без вмешательства рендера.
	var changed := bowl_world.set_vertex(Vector2i(6, 6), 0.0)
	_check(changed, "Высоту можно менять после построения бассейнов")
	basin.ensure_ready()
	_check(is_equal_approx(float(basin.water_at(Vector2i(5, 5))["ground"]),
		bowl_world.height_at(Vector2(5.5, 5.5))), "Грунт и гидрология читают один мир")
	_check(basin.water_at(Vector2i(6, 5))["ground"] > -1.0,
		"Гидрология перестроена по изменённому рельефу")

	# Проверка масштабирования: мир не обязан быть кратен чанкам.
	var partial := WorldMap.new(Config.new(19, 13, 1312, 8, 16))
	var partial_hydro := Hydrology.new(partial)
	partial_hydro.rebuild()
	_topology(partial_hydro, partial.config)
	var last_chunk := WaterMesh.create_mesh(partial, partial_hydro, Vector2i(2, 1))
	_check(last_chunk != null, "Водный рендер принимает неполные крайние чанки")

	if not failures.is_empty():
		for failure in failures:
			push_error("Гидрология: " + failure)
		quit(1)
		return
	print("Этап 3: водосборы, отсутствие циклов, озёра, разливы и сохранения — успешно.")
	quit(0)
