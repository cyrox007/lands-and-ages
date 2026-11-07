extends SceneTree
## 11.8/P1 — физическая нарушенность почвы и постепенное восстановление.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Nature = preload("res://scripts/nature_registry.gd")
const Weather = preload("res://scripts/weather_events.gd")
const Natural = preload("res://scripts/natural_processes.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Fire = preload("res://scripts/fire_registry.gd")
const Landscape = preload("res://scripts/landscape_events.gd")
const Runner = preload("res://scripts/world_day_runner.gd")
const Save = preload("res://scripts/world_save.gd")

const CENTER := Vector2(30.5, 23.5)
var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	# Не прерываем сценарий на первой ошибке: журнал показывает
	# отдельно геологию, экологию, версии и календарную регрессию.
	if not ok:
		failures.append(reason)


func _models() -> Dictionary:
	# Равномерная физическая карта исключает случайные скалы,
	# чтобы проверить само нарушение почвы, а не выбор биома.
	var world := Map.new(Config.new(64, 48, 7291, 16, 32))
	var heights := {}
	for y in range(49):
		for x in range(65):
			heights[Vector2i(x, y)] = 3.5
	_check(world.apply_vertex_changes(heights), "Ровный склон подготовлен")
	world.take_dirty_chunks()
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	_check(climate.set_day(1), "Климат первого дня установлен")
	_check(surface.advance_climate_day(climate), "Почва первого дня рассчитана")
	_check(hydro.apply_rainfall_map(surface.runoff_map()),
		"Водосбор согласован с погодой")
	var nature := Nature.new(world, hydro, surface, climate)
	_check(nature.generate(), "Физическая экосистема создана")
	var weather := Weather.new(world, climate, surface, hydro)
	var natural := Natural.new(world, hydro, surface, climate)
	var disasters := Disasters.new(world, hydro, surface, climate)
	var fire := Fire.new(world, hydro, surface, climate, nature)
	return {
		"world": world, "hydro": hydro, "surface": surface,
		"climate": climate, "nature": nature, "weather": weather,
		"natural": natural, "disasters": disasters, "fire": fire,
		"runner": Runner.new(world, hydro, surface, climate,
			weather, natural, disasters, nature, fire)
	}


func _impact(state: Dictionary) -> Dictionary:
	# Кратер реально меняет WorldMap; след регистрируем только
	# после успешной геологической операции и пересчёта слоёв.
	var world: RefCounted = state["world"]
	var ground: RefCounted = state["surface"]
	var terrain: Dictionary = Landscape.new(world).apply(
		"кратер", CENTER, 8.0, 1.8)
	_check(not terrain.is_empty(), "Кратер реально изменил вершины")
	_check(state["runner"].synchronize_world(),
		"Вода, климат и грунт пересчитаны по новому рельефу")
	var original_heights: Dictionary = world.to_data()
	_check(ground.register_geological_scar(
		"кратер", CENTER, 8.0, 0.95),
		"Нарушение почвы зарегистрировано только в зоне кратера")
	_check(original_heights == world.to_data(),
		"След на почве не создаёт второй массив высот")
	var cell := Vector2i(30, 23)
	var i: int = state["hydro"].cell_index(cell)
	var before: float = ground.geological_scar_at_index(i)
	_check(before > 0.75, "Эпицентр сохраняет сильное разрушение")
	_check(ground.geological_scar_at_index(
		state["hydro"].cell_index(Vector2i(1, 1))) == 0.0,
		"Далёкая почва не меняется")
	var profile: Dictionary = ground.profile_at(cell)
	_check(float(profile["geological_scar"]) == before,
		"Профиль поверхности читает физический след")
	_check(float(profile["fertility"]) < float(profile["base_fertility"]),
		"Разрушение снижает эффективное плодородие")
	_check(float(profile["growth_potential"]) >= 0.0,
		"Потенциал роста остаётся физически определённым")
	_check(ground.register_geological_scar(
		"кратер", CENTER, 8.0, 0.95)
		and ground.geological_scar_at_index(i) >= before
		and ground.geological_scar_at_index(i) <= 1.0,
		"Повторное воздействие ограничено единицей")
	# Запрещённые и бессмысленные события не трогают ни грунт,
	# ни ревизию, ни другой конечный ресурс.
	var saved: Dictionary = ground.to_snapshot()
	var revision: int = ground.revision
	_check(not ground.register_geological_scar(
		"эрозия", CENTER, 8.0, 0.9)
		and not ground.register_geological_scar(
			"кратер", CENTER, -1.0, 0.9)
		and not ground.register_geological_scar(
			"кратер", CENTER, 8.0, NAN),
		"Невалидные команды изменения почвы отклонены")
	_check(ground.to_snapshot() == saved and ground.revision == revision,
		"Отказ не меняет физическое состояние")
	return {"cell": cell, "index": i}


func _event_paths(state: Dictionary, cell: Vector2i) -> void:
	# Проверяем общий суточный контракт: обычный дождевой перенос,
	# нулевая деформация и неверная сила не создают почвенный шрам.
	var ground: RefCounted = state["surface"]
	var initial: Dictionary = ground.to_snapshot()
	var empty: Array[Dictionary] = [
		{"kind": "оползень", "cell": cell, "vertices": 0,
			"severity": 1.0},
		{"kind": "водная эрозия", "cell": cell, "vertices": 2,
			"severity": 1.0},
		{"kind": "землетрясение", "cell": cell, "vertices": 10,
			"severity": 0.0}
	]
	_check(Runner.register_geological_aftermath(ground, empty) == 0,
		"Без подтверждённого разрушения след не создаётся")
	_check(initial == ground.to_snapshot(),
		"Ложные события не изменили поверхность")
	var events: Array[Dictionary] = [
		{"kind": "обвал", "cell": Vector2i(45, 30),
			"vertices": 80, "severity": 0.8},
		{"kind": "землетрясение", "cell": Vector2i(22, 15),
			"vertices": 100, "severity": 0.6}
	]
	_check(Runner.register_geological_aftermath(ground, events) == 2,
		"Обвал и землетрясение обрабатываются отдельно")
	_check(ground.geological_scar_at_index(
		state["hydro"].cell_index(Vector2i(45, 30))) > 0.0
		and ground.geological_scar_at_index(
		state["hydro"].cell_index(Vector2i(22, 15))) > 0.0,
		"Два независимых эпицентра имеют физические следы")


func _save_restore(state: Dictionary, cell: Vector2i, index: int) -> void:
	# Полный WorldSave хранит новые Float32 без квантования; после
	# загрузки восстановление и природные события идут одинаково.
	var snapshot: Dictionary = Save.capture(state)
	_check(not snapshot.is_empty(), "Полный мир с нарушенной почвой сохранён")
	if snapshot.is_empty():
		return
	var copy: Variant = JSON.parse_string(JSON.stringify(snapshot))
	_check(copy is Dictionary, "JSON корректно сериализуется")
	if not (copy is Dictionary):
		return
	var restored: Dictionary = Save.restore(copy)
	_check(not restored.is_empty(), "Полный WorldSave восстанавливается")
	if restored.is_empty():
		return
	_check(restored["surface"].to_snapshot() == state["surface"].to_snapshot(),
		"Снег, вода, наносы и след разрушения возвращаются точно")
	_check(restored["world"].to_data() == state["world"].to_data()
		and restored["nature"].to_data() == state["nature"].to_data(),
		"Геометрия и древесина остались без изменений")

	# Отдельно проверяем совместимость существовавшего снимка v1:
	# он не содержит нового поля, поэтому начинается с чистого грунта.
	var legacy: Dictionary = copy.duplicate(true)
	legacy["surface"]["version"] = 1
	legacy["surface"].erase("geological_scar")
	var old: Dictionary = Save.restore(legacy)
	_check(not old.is_empty(), "Старый снимок Surface v1 загрузился")
	if not old.is_empty():
		_check(old["surface"].geological_scar_at_index(index) == 0.0,
			"Старому миру не приписываем несуществующий след")
		_check(old["surface"].to_snapshot()["version"] == 2,
			"После загрузки старый мир сохраняется в новом формате")

	# Ошибка длины/кодирования и недопустимое отрицательное значение
	# должны быть отвергнуты до записи в живую поверхность.
	var damaged: Dictionary = copy.duplicate(true)
	damaged["surface"]["geological_scar"] = "@broken"
	_check(Save.restore(damaged).is_empty(),
		"Повреждённые данные почвы не загружаются")
	var invalid: Dictionary = copy.duplicate(true)
	var values: PackedFloat32Array = state["surface"]._geological_scar.duplicate()
	values[index] = -0.2
	invalid["surface"]["geological_scar"] = Marshalls.raw_to_base64(
		values.to_byte_array())
	_check(Save.restore(invalid).is_empty(),
		"Неверная отрицательная нарушенность не принимается")

	var old_damage: float = state["surface"].geological_scar_at_index(index)
	for day in range(2, 10):
		state["runner"].run_day()
		restored["runner"].run_day()
		_check(state["world"].to_data() == restored["world"].to_data()
			and state["surface"].to_snapshot() == restored["surface"].to_snapshot()
			and state["nature"].to_data() == restored["nature"].to_data(),
			"Загрузка не меняет ход суток %d" % day)
	var after: float = state["surface"].geological_scar_at_index(index)
	_check(after < old_damage and after > 0.15,
		"Почва медленно восстанавливается, но не за одну неделю")
	_check(restored["surface"].geological_scar_at_index(index) == after,
		"Скорость восстановления не зависит от перезапуска")

	# Длинный климатический цикл после одинаковой загрузки
	# доказывает исчезновение следа без графической анимации.
	for day in range(10, 700):
		state["climate"].set_day(day)
		state["surface"].advance_climate_day(state["climate"])
	_check(state["surface"].geological_scar_at_index(index) < 0.001,
		"После долгого восстановления почва зажила")
	_check(state["surface"].profile_at(cell)["geological_scar"] < 0.001,
		"Профиль отражает физическое исчезновение следа")


func _initialize() -> void:
	# CI выполняет тест без камеры: физические последствия не
	# должны зависеть от разрешения или видимости игрового мира.
	var state: Dictionary = _models()
	var info: Dictionary = _impact(state)
	_event_paths(state, info["cell"])
	_save_restore(state, info["cell"], info["index"])
	if not failures.is_empty():
		for error in failures:
			push_error("11.8/P1: " + error)
		quit(1)
		return
	print("11.8/P1: физический след, регенерация и WorldSave — успешно.")
	quit(0)
