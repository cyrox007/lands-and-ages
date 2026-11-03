extends SceneTree
## Этап 6.4: грозы, разряды, паводки, заболачивание и речные устья.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const WeatherEvents = preload("res://scripts/weather_events.gd")
const Processes = preload("res://scripts/natural_processes.gd")
const Chunk = preload("res://scripts/chunk.gd")

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	if not ok:
		failures.append(reason)


func _make_world() -> Dictionary:
	var world := WorldMap.new(Config.new(96, 64, 1729, 16, 32))
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	var weather := WeatherEvents.new(world, climate, surface, hydro)
	return {
		"map": world, "hydro": hydro, "surface": surface,
		"climate": climate, "weather": weather
	}


func _advance(state: Dictionary, day: int) -> Array[Dictionary]:
	var climate: RefCounted = state["climate"]
	var surface: RefCounted = state["surface"]
	var hydro: RefCounted = state["hydro"]
	climate.set_day(day)
	surface.advance_climate_day(climate)
	hydro.apply_rainfall_map(surface.runoff_map())
	return state["weather"].advance_day(day)


func _test_storms() -> void:
	var a := _make_world()
	var b := _make_world()
	var first: RefCounted = a["weather"]
	var storm_days := 0
	var wet_strikes := 0
	var total := 0
	_check(first.advance_day(4).is_empty(), "Грозы не обгоняют календарь")
	for day in range(1, 97):
		var events_a: Array[Dictionary] = _advance(a, day)
		var events_b: Array[Dictionary] = _advance(b, day)
		_check(events_a == events_b, "Удары молний повторяются по seed и дню")
		_check(first.advance_day(day).is_empty(),
			"Повторная обработка дня не создаёт повторный удар")
		for y in range(8, 64, 12):
			for x in range(8, 96, 12):
				var climate: RefCounted = a["climate"]
				var weather: Dictionary = climate.weather_at(Vector2i(x, y))
				if float(weather["storm_intensity"]) > 0.33:
					storm_days += 1
				_check(float(weather["storm_intensity"]) >= 0.0
					and float(weather["storm_intensity"]) <= 1.0,
					"Грозовая нестабильность ограничена")
				_check(float(weather["precipitation"]) >= 0.0
					and float(weather["precipitation"]) <= 3.0,
					"Интенсивный ливень ограничен бюджетом осадков")
		for event in events_a:
			total += 1
			var cell: Vector2i = event["cell"]
			_check(a["map"].config.contains_cell(cell), "Молния поражает реальную клетку")
			_check(float(event["strength"]) >= WeatherEvents.MIN_STORM,
				"Молния возникает только внутри грозового фронта")
			_check(float(event["ignition_potential"]) >= 0.0
				and float(event["ignition_potential"]) <= 1.0,
				"Риск возгорания зависит от условий поверхности")
			if float(a["climate"].weather_at(cell)["rainfall"]) > 0.8:
				wet_strikes += 1
	_check(storm_days > 0, "За год формируются реальные грозовые области")
	_check(total > 0, "За год молнии ударяют в землю")
	_check(total == first.total_strikes, "Счётчик молний соответствует событиям")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(first.to_data()))
	var restored := WeatherEvents.new(a["map"], a["climate"], a["surface"], a["hydro"])
	_check(restored.load_data(saved), "История молний восстанавливается")
	_check(restored.advance_day(96).is_empty(),
		"Загрузка не повторяет удары последнего дня")
	_check(restored.total_strikes == total,
		"После загрузки сохраняется число физических ударов")
	var invalid: Dictionary = saved.duplicate(true)
	invalid["last_day"] = 999
	_check(not restored.load_data(invalid), "Нельзя восстановить события будущих дней")
	invalid = saved.duplicate(true)
	invalid["world_signature"] = "подмена"
	_check(not restored.load_data(invalid), "Чужой мир отвергается")
	print("Грозы: участков=", storm_days, " · ударов=", total,
		" · ударов во время ливня=", wet_strikes)


func _test_flood_and_wetlands() -> void:
	var world := WorldMap.new(Config.new(12, 12, 9123))
	var heights := {}
	for y in range(13):
		for x in range(13):
			heights[Vector2i(x, y)] = -1.0 if x >= 4 and x <= 8 \
				and y >= 4 and y <= 8 else 2.0
	_check(world.apply_vertex_changes(heights),
		"Котловина для паводка формируется единой высотной картой")
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	_check(hydro.set_rainfall(2.2), "Сильный ливень наполняет водосбор")
	var flooded: Dictionary = hydro.water_count()
	_check(int(flooded["flooded"]) > 0, "Ливень затапливает соседнюю пойму")
	var flood_cell := Vector2i(-1, -1)
	for y in range(12):
		for x in range(12):
			var cell := Vector2i(x, y)
			if hydro.flood_depth_at(hydro.cell_index(cell)) > 0.0:
				flood_cell = cell
				break
		if flood_cell.x >= 0:
			break
	_check(flood_cell.x >= 0, "Паводок имеет физическую глубину воды")
	_check(hydro.set_rainfall(0.0), "После ливня сток снижается")
	_check(int(hydro.water_count()["flooded"]) == 0,
		"Паводок отступает, не оставляя вечной лужи в гидрологии")
	if flood_cell.x >= 0:
		_check(hydro.flood_depth_at(hydro.cell_index(flood_cell)) == 0.0,
			"После отступления вода в пойме исчезает")
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	for day in range(70):
		surface.advance_day(2.6, 16.0)
		hydro.apply_rainfall_map(surface.runoff_map())
	var max_waterlogging := 0.0
	for y in range(12):
		for x in range(12):
			var soil: Dictionary = surface.profile_at(Vector2i(x, y))
			max_waterlogging = maxf(max_waterlogging,
				float(soil["waterlogging"]))
	_check(max_waterlogging > 0.5,
		"Многодневные дожди накапливают заболачивание")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(surface.to_data()))
	var restored := Surface.new(world, hydro)
	restored.rebuild()
	_check(restored.load_data(saved), "Заболоченность сохраняется в формате 4")
	var older: Dictionary = saved.duplicate(true)
	older["version"] = 3
	older.erase("waterlogging")
	_check(restored.load_data(older), "Сохранения поверхности версии 3 читаются")
	older["version"] = 2
	older.erase("sediment_changes")
	_check(restored.load_data(older), "Сохранения поверхности версии 2 читаются")
	var broken: Dictionary = saved.duplicate(true)
	broken["waterlogging"] = "AA=="
	_check(not restored.load_data(broken), "Повреждённый слой болота отклоняется")
	var mesh := Chunk.create_mesh(0, 0, 1, world, surface, 7)
	_check(mesh.get_surface_count() == 1,
		"GPU имеет слой паводков и заболоченных земель")
	print("Паводок: затоплено=", flooded["flooded"],
		" · заболачивание=", max_waterlogging)


func _test_delta() -> void:
	var world := WorldMap.new(Config.new(48, 32, 4271, 16, 32))
	var heights := {}
	for y in range(33):
		for x in range(49):
			var height := -1.0 if x <= 8 else (
				float(x - 8) * 0.17 + absf(float(y - 16)) * 0.36)
			heights[Vector2i(x, y)] = height
	_check(world.apply_vertex_changes(heights), "Создан уклон к настоящему морю")
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	var processes := Processes.new(world, hydro, surface, climate)
	var found := false
	for y in range(32):
		for x in range(48):
			var cell := Vector2i(x, y)
			var i: int = hydro.cell_index(cell)
			if not hydro.river_mouth_at(i):
				continue
			var risk: Dictionary = processes.estimate_at(cell)
			if float(risk.get("delta", 0.0)) <= 0.0:
				continue
			var destination: Vector2i = risk["delta_target"]
			_check(hydro.ocean_at(hydro.cell_index(destination)),
				"Речной нанос направлен только в связное море")
			var before := world.vertex_at(destination)
			var total := surface.sediment_balance()
			_check(surface.transfer_sediment(cell, destination, 0.01),
				"Нанос с речного устья откладывается на мелководье")
			_check(world.vertex_at(destination) > before,
				"Дно устья постепенно повышается")
			_check(absf(surface.sediment_balance() - total) < 0.0001,
				"Речная дельта не создаёт грунт из ничего")
			found = true
			break
		if found:
			break
	_check(found, "На направленном к морю водосборе образуется устье")
	print("Устье: ", found)


func _initialize() -> void:
	_test_storms()
	_test_flood_and_wetlands()
	_test_delta()
	if not failures.is_empty():
		for reason in failures:
			push_error("Этап 6.4: " + reason)
		quit(1)
		return
	print("Этап 6.4: грозы, молнии, ливни, паводки, болота и дельты — успешно.")
	quit(0)
