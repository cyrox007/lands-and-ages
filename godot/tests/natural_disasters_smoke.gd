extends SceneTree
## Приёмка 6.5: реальные условия, последствия, сохранение и воспроизводимость.

const Config = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")

var failures: Array[String] = []


func _check(value: bool, reason: String) -> void:
	if not value:
		failures.append(reason)


func _make_world(seed: int = 1729) -> Dictionary:
	var world := WorldMap.new(Config.new(64, 48, seed, 16, 32))
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	var disasters := Disasters.new(world, hydro, surface, climate)
	return {
		"world": world, "hydro": hydro,
		"surface": surface, "climate": climate,
		"disasters": disasters
	}


func _next(state: Dictionary, day: int) -> Array[Dictionary]:
	var climate: RefCounted = state["climate"]
	var surface: RefCounted = state["surface"]
	var hydro: RefCounted = state["hydro"]
	_check(climate.set_day(day), "Климат принимает суточный шаг")
	_check(surface.advance_climate_day(climate),
		"Поверхность принимает суточный шаг")
	_check(hydro.apply_rainfall_map(surface.runoff_map()),
		"Физический сток питает водосбор")
	return state["disasters"].advance_day(day)


func _test_calendar() -> void:
	var first := _make_world()
	var second := _make_world()
	var events_a: RefCounted = first["disasters"]
	var histogram := {}
	var total := 0
	_check(events_a.conditions_at(Vector2i(-1, 4)).is_empty(),
		"За пределами карты не существует природных рисков")
	_check(events_a.advance_day(3).is_empty(),
		"Стихийный симулятор не обгоняет климат")
	for day in range(1, 97):
		var a: Array[Dictionary] = _next(first, day)
		var b: Array[Dictionary] = _next(second, day)
		_check(a == b, "События полностью детерминированы по seed и календарю")
		_check(events_a.advance_day(day).is_empty(),
			"Повторный вызов дня не повторяет бедствие")
		_check(a.size() <= Disasters.MAX_EVENTS_PER_DAY,
			"Количество чрезвычайных событий за день ограничено")
		_check(JSON.stringify(first["world"].to_data())
			== JSON.stringify(second["world"].to_data()),
			"Геометрия двух независимых симуляций совпадает")
		for event in a:
			var kind: String = event["kind"]
			var cell: Vector2i = event["cell"]
			_check(first["world"].config.contains_cell(cell),
				"Природное событие имеет координату на карте")
			_check(float(event["severity"]) >= 0.0
				and float(event["severity"]) <= 1.0,
				"Интенсивность физического события ограничена")
			histogram[kind] = int(histogram.get(kind, 0)) + 1
			total += 1
	_check(total > 0, "На годовом прогоне возникают реальные природные события")
	_check(total == events_a.total_events, "Счётчик стихийных событий непротиворечив")
	var saved: Dictionary = JSON.parse_string(JSON.stringify(events_a.to_data()))
	var restored := Disasters.new(first["world"], first["hydro"],
		first["surface"], first["climate"])
	_check(restored.load_data(saved), "Годовая история событий и накопленные риски читаются")
	_check(restored.to_data() == events_a.to_data(),
		"Повторная загрузка сохраняет текущую фазу опасностей")
	_check(restored.advance_day(96).is_empty(),
		"Восстановленный день не проигрывается дважды")
	var damaged := saved.duplicate(true)
	damaged["world_signature"] = "другой мир"
	_check(not restored.load_data(damaged),
		"Запрещена загрузка бедствий с чужой картой")
	damaged = saved.duplicate(true)
	damaged["strain"] = [1.0]
	_check(not restored.load_data(damaged),
		"Повреждённый слой тектонического напряжения отвергается")
	damaged = saved.duplicate(true)
	damaged["droughts"] = [-1, 0, 0, 0]
	_check(not restored.load_data(damaged),
		"Отрицательные периоды засухи отклоняются")
	print("Стихийные события за год: ", histogram, " · всего: ", total)


func _test_snow_and_sediment() -> void:
	# Уклон 2.5 единицы/клетку, вся высотная карта остаётся в пределах.
	var world := WorldMap.new(Config.new(16, 16, 4471, 8, 16))
	var changes := {}
	for y in range(17):
		for x in range(17):
			changes[Vector2i(x, y)] = 4.0 + (16.0 - float(x)) * 2.5
	_check(world.apply_vertex_changes(changes), "Снежный склон создан атомарно")
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	var disasters := Disasters.new(world, hydro, surface, climate)
	var source := Vector2i(8, 8)
	var target := Vector2i(9, 8)
	var index: int = hydro.cell_index(source)
	var next: int = hydro.cell_index(target)
	for day in range(3):
		surface.advance_day(3.0, -12.0)
	# Тестовая подготовка: за ближайшим уступом уже сошёл старый снег.
	surface._snow[next] = 0.05
	surface._snow[index] = 0.9
	var mass_before: float = surface._snow[index] + surface._snow[next]
	var height_before: float = world.vertex_at(source)
	var avalanche: Dictionary = disasters.conditions_at(source)
	_check(float(avalanche["лавина"]) > 0.1,
		"Снег на крутом склоне создаёт риск лавины")
	var event: Dictionary = disasters._slope_event("лавина", source, 0.10)
	_check(not event.is_empty() and float(event.get("snow_volume", 0.0)) > 0.0,
		"Лавина переносит реальный снег вниз")
	_check(absf(surface._snow[index] + surface._snow[next] - mass_before) < 0.00001,
		"Лавина не создаёт и не уничтожает снежную массу")
	_check(is_equal_approx(world.vertex_at(source), height_before),
		"Снежная лавина не сдвигает скальный рельеф")
	_check(not surface.transfer_snow(target, source, 0.2),
		"Снежная масса не перемещается вверх по склону")

	# На том же склоне смоделируем толстый переувлажнённый щебень.
	surface._type[index] = Surface.GRAVEL
	surface._depth[index] = 2.0
	surface._moisture[index] = 0.99
	surface._runoff[index] = 2.8
	var mud_risk: Dictionary = disasters.conditions_at(source)
	_check(float(mud_risk["сель"]) > 0.10,
		"Сток и насыщенный рыхлый грунт создают риск селя")
	var initial_balance: float = surface.sediment_balance()
	var revision: int = world.revision
	var slide: Dictionary = disasters._slope_event("сель", source, 0.10)
	_check(not slide.is_empty() and world.revision > revision,
		"Сель переносит грунт и изменяет реальную геометрию")
	_check(absf(surface.sediment_balance() - initial_balance) < 0.0001,
		"Сель сохраняет суммарный баланс наносов")
	_check(disasters._slope_event("лавина", Vector2i(-1, -1), 0.1).is_empty(),
		"Недопустимые координаты стихийного события отвергаются")


func _test_faults() -> void:
	# Отдельная территория может быть тектонически спокойной:
	# разломы не обязаны проходить через каждую карту и любой seed.
	var state := _make_world(1729)
	var disasters: RefCounted = state["disasters"]
	var high := 0.0
	var low := 1.0
	for y in range(48):
		for x in range(64):
			var risk: float = disasters.fault_risk_at(Vector2i(x, y))
			high = maxf(high, risk)
			low = minf(low, risk)
			_check(risk >= 0.0 and risk <= 1.0, "Геологический риск ограничен")
	_check(high > low, "Риск разлома образует пространственно плавные области")
	_check(disasters.fault_risk_at(Vector2i(-1, 0)) == 0.0,
		"Вне мира нет геологических событий")


func _initialize() -> void:
	_test_snow_and_sediment()
	_test_faults()
	_test_calendar()
	if not failures.is_empty():
		for failure in failures:
			push_error("Этап 6.5: " + failure)
		quit(1)
		return
	print("Этап 6.5: бедствия, физические последствия, сохранения и seed — успешно.")
	quit(0)
