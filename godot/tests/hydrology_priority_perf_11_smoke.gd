extends SceneTree
## 11/HYDRO-HEAP: точность маршрутизации Priority-Flood на 256×192.
## Эталон с прежней очередью и оптимизированная версия работают
## над ОДНИМ рельефом. Сравниваются сырые байты каждого поля,
## включая далёкие водоразделы, озёра и затопления.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Legacy = preload("res://tests/hydrology_priority_legacy.gd")
const WIDTH := 256
const HEIGHT := 192
const SEEDS := [1729, 2608]
var failures: Array[String] = []
var old_us := 0
var new_us := 0
var measured := 0


func _check(ok: bool, reason: String) -> void:
	# Все физические расхождения регистрируем вместе, но
	# не допускаем маскировки одной ошибки временем теста.
	if not ok and failures.size() < 45:
		failures.append(reason)


func _compare(old: RefCounted, current: RefCounted, stage: String) -> void:
	# Байтовое равенство не путает NaN сухой клетки с NaN
	# другого участка и проверяет точные float32 уровни,
	# дождь, влажность и направления на ВСЕЙ карте.
	for field in ["_ground", "_spill", "_downstream", "_outlet",
			"_order", "_rank", "_catchment", "_discharge", "_local_rain",
			"_ocean", "_lake", "_river", "_flood", "_water_level", "_wetness"]:
		var a: Variant = old.get(field)
		var b: Variant = current.get(field)
		_check(a.to_byte_array() == b.to_byte_array(),
			"Поле %s идентично: %s" % [field, stage])
	_check(old._summary == current._summary, "Количество воды: " + stage)
	_check(old.to_snapshot() == current.to_snapshot(),
		"Снимок гидрологии одинаков: " + stage)
	_check(old.last_ground_cells == current.last_ground_cells,
		"Оба алгоритма прочитали одинаковый рельеф: " + stage)
	_check(old.full_rebuilds == current.full_rebuilds,
		"Число настоящих пересчётов одинаково: " + stage)
	var changed_old: Array = old.last_changed_chunks.duplicate()
	var changed_new: Array = current.last_changed_chunks.duplicate()
	changed_old.sort()
	changed_new.sort()
	_check(changed_old == changed_new, "Вода изменила те же чанки: " + stage)


func _topology(hydro: RefCounted, stage: String) -> void:
	# Отдельно от эталона контролируем физические инварианты:
	# поток не образует цикл, ранги уменьшаются по направлению
	# воды, сумма площадей у граничных выходов равна всей карте.
	var outlet_area := 0.0
	for index in range(WIDTH * HEIGHT):
		var lower: int = hydro._downstream[index]
		if lower < 0:
			outlet_area += float(hydro._catchment[index])
			var x := index % WIDTH
			var y := int(index / WIDTH)
			_check(x == 0 or y == 0 or x == WIDTH - 1 or y == HEIGHT - 1,
				"Выход водосбора на границе: " + stage)
			continue
		_check(hydro._rank[lower] < hydro._rank[index],
			"Нет циклов и движение к выходу: " + stage)
	_check(absf(outlet_area - float(WIDTH * HEIGHT)) < 0.15,
		"Вся площадь водосбора сохраняется: " + stage)


func _rain_map() -> PackedFloat32Array:
	# Пространственные осадки не должны прятать расхождение
	# гидрологии в режиме равномерного дождя.
	var values := PackedFloat32Array()
	values.resize(WIDTH * HEIGHT)
	for i in range(values.size()):
		values[i] = 0.25 + float(i % 43) / 40.0
	return values


func _rebuild_pair(old: RefCounted, current: RefCounted,
		stage: String, optimized_first: bool) -> void:
	# Меняем порядок запусков, чтобы в CI прогрев процессора
	# не давал новому алгоритму систематическую фору.
	var start := Time.get_ticks_usec()
	if optimized_first:
		current.rebuild()
		new_us += Time.get_ticks_usec() - start
		start = Time.get_ticks_usec()
		old.rebuild()
		old_us += Time.get_ticks_usec() - start
	else:
		old.rebuild()
		old_us += Time.get_ticks_usec() - start
		start = Time.get_ticks_usec()
		current.rebuild()
		new_us += Time.get_ticks_usec() - start
	measured += 1
	_compare(old, current, stage)
	_topology(current, stage)
	print("HYDRO-HEAP/STEP: ", stage, ", прежний/новый мкс=",
		old_us, "/", new_us, ", часть рельефа=",
		current.last_ground_cells)


func _run() -> void:
	var rainfall := _rain_map()
	for seed in SEEDS:
		var world := Map.new(Config.new(WIDTH, HEIGHT, seed, 16, 32))
		var old := Legacy.new(world)
		var current := Hydro.new(world)
		_rebuild_pair(old, current, "исходная карта %d" % seed, seed != SEEDS[0])
		_check(old.apply_rainfall_map(rainfall)
			and current.apply_rainfall_map(rainfall),
			"Настоящий неоднородный сток применён")
		_compare(old, current, "осадки %d" % seed)

		# Изменяем общие вершины физического WorldMap, а не
		# рисуем условный водораздел в фиктивном массиве.
		var center := Vector2i(120, 89)
		var old_height: float = world.vertex_at(center)
		_check(world.apply_vertex_changes({
			center: old_height + 0.037,
			center + Vector2i(1, 0): world.vertex_at(
				center + Vector2i(1, 0)) - 0.027
		}), "Правка двух вершин мира")
		_rebuild_pair(old, current, "локальная геология %d" % seed,
			seed == SEEDS[0])
		# Следующий план меняет участок у края карты:
		# это особенно важно для выхода стока и океана.
		var border := Vector2i(0, 93)
		_check(world.apply_vertex_changes({
			border: world.vertex_at(border) + 0.22
		}), "Геология на границе карты")
		_rebuild_pair(old, current, "граница %d" % seed,
			seed != SEEDS[0])

		# Свежий полный пересчёт в другом объекте должен
		# дать те же удалённые реки, что старый инкрементальный.
		var fresh := Hydro.new(world)
		fresh.rebuild()
		fresh.apply_rainfall_map(rainfall)
		# Число выполненных rebuild у свежей модели отличается,
		# поэтому физические массивы проверяем независимо.
		for field in ["_spill", "_downstream", "_outlet", "_rank",
				"_catchment", "_discharge", "_lake", "_river", "_ocean",
				"_flood", "_water_level", "_wetness"]:
			_check(current.get(field).to_byte_array()
				== fresh.get(field).to_byte_array(),
				"Глобальная контрольная перестройка: " + field)

	var ratio := float(new_us) / float(maxi(1, old_us))
	print("HYDRO-HEAP: прогонов=", measured, ", прежняя очередь=",
		old_us, " мкс, новая=", new_us, " мкс, коэффициент=", ratio)
	# Производительность засчитывается по одинаковым реальным
	# топологиям; любая физическая разница проваливает CI.
	_check(ratio < 0.95,
		"Очередь ускорила полный Priority-Flood минимум на 5%")
	if not failures.is_empty():
		for failure in failures:
			push_error("HYDRO-HEAP: " + failure)
		print("HYDRO-HEAP: нарушений=", failures.size())
		quit(1)
		return
	print("HYDRO-HEAP: 256×192, водосборы, озёра, дальние реки — успешно")
	quit(0)


func _initialize() -> void:
	call_deferred("_run")
