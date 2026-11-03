extends SceneTree
## Этап 6.2: процессы изменяют карту воспроизводимо и малыми шагами.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Processes = preload("res://scripts/natural_processes.gd")

var failures: Array[String] = []


func _check(valid: bool, message: String) -> void:
	if not valid:
		failures.append(message)


func _make_world() -> Dictionary:
	var map := WorldMap.new(Config.new(64, 48, 1729, 16, 32))
	var hydro := Hydrology.new(map)
	hydro.rebuild()
	var surface := Surface.new(map, hydro)
	surface.rebuild()
	var climate := Climate.new(map, hydro)
	climate.rebuild()
	var processes := Processes.new(map, hydro, surface, climate)
	return {
		"map": map, "hydro": hydro, "surface": surface,
		"climate": climate, "processes": processes
	}


func _step(state: Dictionary, day: int) -> Dictionary:
	var climate: RefCounted = state["climate"]
	var surface: RefCounted = state["surface"]
	var hydro: RefCounted = state["hydro"]
	climate.set_day(day)
	surface.advance_climate_day(climate)
	hydro.apply_rainfall_map(surface.runoff_map())
	var result: Dictionary = state["processes"].advance_day(day)
	if not result.is_empty():
		var map: RefCounted = state["map"]
		var chunks: Array[Vector2i] = map.take_dirty_chunks()
		hydro.rebuild()
		climate.rebuild()
		hydro.apply_rainfall_map(surface.runoff_map())
		surface.rebuild(chunks)
		surface.synchronize_climate(climate)
	return result


func _height_sum(map: RefCounted) -> float:
	var total := 0.0
	for y in range(map.config.height + 1):
		for x in range(map.config.width + 1):
			total += map.vertex_at(Vector2i(x, y))
	return total


func _initialize() -> void:
	var first := _make_world()
	var second := _make_world()
	var changed := 0
	var counts := {"water": 0, "wind": 0, "slide": 0, "coast": 0, "delta": 0}
	var initial_map: RefCounted = first["map"]
	var initial_sum := _height_sum(initial_map)
	var first_process: RefCounted = first["processes"]
	_check(first_process.estimate_at(Vector2i(-1, -1)).is_empty(),
		"Риск за пределами карты не вычисляется")
	_check(first_process.advance_day(4).is_empty(),
		"Нельзя рассчитать будущий день без климата")

	for day in range(1, 97):
		var a: Dictionary = _step(first, day)
		var b: Dictionary = _step(second, day)
		_check(a.get("process", "") == b.get("process", ""),
			"Решение о процессе одинаково при одном seed и календаре")
		_check(JSON.stringify(first["map"].to_data())
			== JSON.stringify(second["map"].to_data()),
			"Физическая карта воспроизводится независимо от запуска")
		_check(first_process.advance_day(day).is_empty(),
			"Повторный вызов не запускает процесс второй раз")
		if day == 4:
			var maxima := {"water": 0.0, "wind": 0.0, "slide": 0.0}
			for y in range(first["map"].config.height):
				for x in range(first["map"].config.width):
					var risk: Dictionary = first_process.estimate_at(Vector2i(x, y))
					if risk.is_empty():
						continue
					for kind in maxima.keys():
						maxima[kind] = maxf(maxima[kind], risk[kind])
			print("Максимальные природные риски: ", maxima)
		if a.is_empty():
			continue
		changed += 1
		counts[a["process"]] = int(counts[a["process"]]) + 1
		_check(day % Processes.STEP_DAYS == 0,
			"Редкие геологические изменения не происходят каждый кадр")
		_check(int(a["vertices"]) >= 2,
			"Физическая деформация меняет минимум две вершины")
		_check(float(a.get("volume", 0.001)) <= 0.18,
			"Природные воздействия малы по сравнению с катастрофами")
	_check(changed >= 1, "За один игровой год есть естественное изменение рельефа")
	_check(int(counts["water"]) > 0 and int(counts["wind"]) > 0,
		"Вода и ветер оба участвуют в природном переносе грунта")
	_check(initial_map.changed_vertex_count() >= 2,
		"Карта на самом деле хранит изменения высот")
	_check(absf(_height_sum(initial_map) - initial_sum) < 0.05,
		"Перенос грунта не создаёт заметную массу из ничего")
	print("Природные процессы за год: ", counts, " · изменений: ", changed)

	var saved: Dictionary = JSON.parse_string(
		JSON.stringify(first_process.to_data()))
	var restored := Processes.new(first["map"], first["hydro"],
		first["surface"], first["climate"])
	_check(restored.load_data(saved), "День природных процессов восстанавливается")
	_check(restored.advance_day(96).is_empty(),
		"После загрузки прошедший день не применяется повторно")
	_check(not restored.load_data({"version": 999}),
		"Чужой формат сохранения запрещён")
	var damaged := saved.duplicate(true)
	damaged["last_day"] = -3
	_check(not restored.load_data(damaged), "Нельзя откатить календарь в минус")
	damaged = saved.duplicate(true)
	damaged["world_signature"] = "повреждённая карта"
	_check(not restored.load_data(damaged),
		"История процессов не подходит другой карте")

	if not failures.is_empty():
		for failure in failures:
			push_error("Этап 6.2: " + failure)
		quit(1)
		return
	print("Этап 6.2: естественная эрозия, календарь, баланс и сохранение — успешно.")
	quit(0)
