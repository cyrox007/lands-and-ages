extends SceneTree
## 11.7 — физические обвалы и кратеры, сохранения и согласованность высот.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Landscape = preload("res://scripts/landscape_events.gd")
const Chunk = preload("res://scripts/chunk.gd")

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	# Накапливаем все нарушения отдельно, чтобы один прогон CI
	# показал не только первую ошибку, но и остальные инварианты.
	if not ok:
		failures.append(reason)


func _models() -> Dictionary:
	# Создаём детерминированный обрыв, а не подменяем нормаль склона.
	# Слева — высокая скала, справа — плато, между ними перепад.
	var world := Map.new(Config.new(48, 40, 4471, 16, 32))
	var heights := {}
	for y in range(41):
		for x in range(49):
			var elevation := 11.0 + clampf((36.0 - float(x)) * 1.9, 0.0, 45.6)
			heights[Vector2i(x, y)] = elevation
	_check(world.apply_vertex_changes(heights), "Исходная скала сформирована")
	world.take_dirty_chunks()
	var hydro := Hydro.new(world)
	hydro.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	return {
		"world": world, "hydro": hydro, "surface": surface,
		"climate": climate,
		"disasters": Disasters.new(world, hydro, surface, climate)
	}


func _total_height(world: RefCounted) -> float:
	# Суммируем физические вершины, а не высоты графического меша.
	# Для локального перемещения материала сумма почти неизменна;
	# допускается только округление WorldMap до миллионных долей.
	var amount := 0.0
	for y in range(world.config.height + 1):
		for x in range(world.config.width + 1):
			amount += world.vertex_at(Vector2i(x, y))
	return amount


func _exercise(state: Dictionary) -> Dictionary:
	# Проверяем обвал через действующий обработчик природных бедствий:
	# событие не должно запускаться на песке и не рисуется само по себе.
	var world: RefCounted = state["world"]
	var hydro: RefCounted = state["hydro"]
	var surface: RefCounted = state["surface"]
	var climate: RefCounted = state["climate"]
	var disasters: RefCounted = state["disasters"]
	var source := Vector2i(24, 19)
	var index: int = hydro.cell_index(source)
	surface._type[index] = Surface.ROCK
	var risk: Dictionary = disasters.conditions_at(source)
	var rock_risk := float(risk.get("обвал", 0.0))
	_check(rock_risk > 0.20, "Крутой скальный склон имеет риск обвала")
	surface._type[index] = Surface.GRAVEL
	_check(float(disasters.conditions_at(source)["обвал"]) == 0.0,
		"Рыхлый грунт не выдаётся за скальный обвал")
	surface._type[index] = Surface.ROCK

	var mass_before := _total_height(world)
	var revision_before: int = world.revision
	var rockfall: Dictionary = disasters._slope_event(
		"обвал", source, rock_risk * 0.9)
	_check(not rockfall.is_empty(), "Обвал проходит через физическую модель")
	_check(int(rockfall.get("vertices", 0)) > 0
		and world.revision == revision_before + 1,
		"Обвал атомарно обновляет ревизию настоящих высот")
	_check(absf(_total_height(world) - mass_before) < 0.006,
		"Скальный обвал переносит массу без её создания")

	# Кратер появляется от локального воздействия: в центре глубже,
	# по краю образуется вал той же породы. Он не является случайным
	# побочным эффектом обычного землетрясения.
	var landscape := Landscape.new(world)
	var center := Vector2(30.0, 21.0)
	var pit := Vector2i(30, 21)
	var rim := Vector2i(36, 21)
	var before_pit: float = world.vertex_at(pit)
	var before_rim: float = world.vertex_at(rim)
	mass_before = _total_height(world)
	revision_before = world.revision
	var impact: Dictionary = landscape.apply("кратер", center, 8.0, 1.4)
	_check(not impact.is_empty() and int(impact.get("vertices", 0)) > 100,
		"Удар создаёт область физического рельефа, а не одну клетку")
	_check(world.revision == revision_before + 1,
		"Ударный кратер — одна атомарная правка WorldMap")
	_check(world.vertex_at(pit) < before_pit - 1.3,
		"В центре кратера образуется физическая впадина")
	_check(world.vertex_at(rim) > before_rim,
		"Выброшенная порода образует кольцевой вал")
	_check(absf(_total_height(world) - mass_before) < 0.006,
		"Глубина кратера компенсируется породой на валу")

	# Некорректное воздействие не допускает частичной деформации.
	revision_before = world.revision
	_check(landscape.apply("кратер", Vector2(2, 2), 6.0, 1.0).is_empty()
		and landscape.apply("кратер", center, 2.5, 1.0).is_empty()
		and landscape.apply("обвал", Vector2(40, 10), 6.0, 0.3).is_empty(),
		"Краевые, слишком малые и безуклонные события отклонены")
	_check(world.revision == revision_before,
		"Недопустимые события не изменили геометрию")

	# Сигнал WorldMap оставляет список загрязнённых чанков; по нему
	# восстанавливаем физическую воду/почву и сравниваем общую высоту.
	var changed: Array[Vector2i] = world.take_dirty_chunks()
	_check(changed.size() >= 2, "Обвал и кратер обновляют соседние чанки")
	hydro.ensure_ready()
	surface.rebuild(changed)
	climate.rebuild()
	_check(absf(float(hydro.water_at(pit)["ground"])
		- world.height_at(center + Vector2(0.5, 0.5))) < 0.0001,
		"Гидрология читает изменённую физическую поверхность")

	# Оба чанка берут одну и ту же пограничную вершину WorldMap.
	var left := Chunk.create_mesh(1, 1, 1, world, surface, 0, climate)
	var right := Chunk.create_mesh(2, 1, 1, world, surface, 0, climate)
	var a: PackedVector3Array = left.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var b: PackedVector3Array = right.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for row in range(17):
		_check(a[row * 17 + 16].distance_to(b[row * 17]) < 0.0001,
			"После кратера нет разрыва между графическими чанками")

	# Храним только изменённые вершины, без дублирования высот.
	# Загрузка даёт точное совпадение с текущим физическим миром.
	var saved: Dictionary = JSON.parse_string(JSON.stringify(world.to_data()))
	var restored := Map.from_data(saved)
	_check(restored != null, "WorldMap загружает обвал и кратер из JSON")
	if restored != null:
		_check(restored.to_data() == world.to_data(),
			"Восстановлены все деформированные вершины без расхождений")
	return world.to_data()


func _initialize() -> void:
	# Прогон на одинаковом seed должен воспроизвести одинаковый
	# результат, не используя GPU, таймер и глобальный RNG.
	var first: Dictionary = _exercise(_models())
	var second: Dictionary = _exercise(_models())
	_check(first == second, "Физические деформации детерминированы")
	if not failures.is_empty():
		for failure in failures:
			push_error("11.7: " + failure)
		quit(1)
		return
	print("11.7: обвалы, кратеры, баланс, чанки и JSON — успешно.")
	quit(0)
