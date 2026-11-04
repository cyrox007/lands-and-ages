extends SceneTree
## Этап 7.3: неизменность гидрологии и региональных угроз после оптимизации.

const Config = preload("res://scripts/world_config.gd")
const Map = preload("res://scripts/world_map.gd")
const Hydro = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Disasters = preload("res://scripts/natural_disasters.gd")
const Terrain = preload("res://scripts/terrain.gd")
const Natural = preload("res://scripts/natural_processes.gd")

var failures: Array[String] = []


func _check(ok: bool, reason: String) -> void:
	if not ok:
		failures.append(reason)


func _check_water(a: RefCounted, b: RefCounted, count: int) -> void:
	_check(a.water_count() == b.water_count(), "Счётчики рек и озёр совпадают")
	_check(a._ground == b._ground, "Высоты клеток совпадают побитово")
	_check(a._spill == b._spill, "Уровни перелива совпадают")
	_check(a._downstream == b._downstream, "Граф стока совпадает")
	_check(a._outlet == b._outlet, "Водоразделы и выходы совпадают")
	_check(a._order == b._order, "Порядок priority-flood совпадает")
	_check(a._catchment == b._catchment, "Площади водосборов совпадают")
	_check(a._discharge == b._discharge, "Расход рек совпадает")
	_check(a._ocean == b._ocean, "Связность океана совпадает")
	_check(a._river == b._river, "Русла совпадают")
	_check(a._lake == b._lake, "Озёрные котловины совпадают")
	_check(a._flood == b._flood, "Паводковые клетки совпадают")
	_check(a._wetness == b._wetness, "Поверхностная влажность совпадает")
	for i in range(0, count, maxi(1, count / 173)):
		var level_a: float = a.level_at(i)
		var level_b: float = b.level_at(i)
		_check((is_nan(level_a) and is_nan(level_b)) or level_a == level_b,
			"Физический уровень воды не изменился от оптимизации")


func _test_hydrology(width: int, height: int) -> void:
	var config := Config.new(width, height, 1729, 16, 32)
	var first := Map.new(config)
	var second := Map.new(Config.new(width, height, 1729, 16, 32))
	var incremental := Hydro.new(first)
	var reference := Hydro.new(second)
	incremental.rebuild()
	reference.rebuild()
	var rain := PackedFloat32Array()
	rain.resize(width * height)
	for i in range(rain.size()):
		rain[i] = 0.2 + float(i % 13) * 0.08
	_check(incremental.apply_rainfall_map(rain), "Карта осадков принята")
	_check(reference.apply_rainfall_map(rain), "Те же осадки приняты эталоном")
	var coordinates := [
		Vector2i(20, 19), Vector2i(width / 2, height / 2),
		Vector2i(width - 21, height - 19)
	]
	var edits_a := {}
	var edits_b := {}
	for cell in coordinates:
		var new_height: float = first.vertex_at(cell) + 0.055
		edits_a[cell] = new_height
		edits_b[cell] = new_height
	_check(first.apply_vertex_changes(edits_a), "Пакетная деформация принята")
	_check(second.apply_vertex_changes(edits_b), "Та же деформация в эталоне")
	# Другой потребитель мог уже забрать очередь GPU.
	first.take_dirty_chunks()
	var partial_start := Time.get_ticks_usec()
	incremental.ensure_ready()
	var partial_us := Time.get_ticks_usec() - partial_start
	var updated: int = incremental.last_ground_cells
	# Без журнала изменённых чанков выполняется прежняя полная геометрия.
	reference._geometry_dirty.clear()
	var full_start := Time.get_ticks_usec()
	reference.ensure_ready()
	var full_us := Time.get_ticks_usec() - full_start
	_check(updated > 0 and updated < width * height,
		"Гидрология читает только изменённые физические клетки")
	_check(reference.last_ground_cells == width * height,
		"Эталон перечитывает всю поверхность карты")
	_check(incremental.total_ground_cells == width * height + updated,
		"Суммарные объёмы чтения высот измеряются без пропусков")
	_check(incremental.full_rebuilds == reference.full_rebuilds,
		"Количество запусков priority-flood не меняется")
	_check(incremental.ocean_revision == reference.ocean_revision,
		"Изменение морской связности определяется одинаково")
	_check_water(incremental, reference, width * height)
	print("Этап 7.3, ", width, "×", height,
		": локально ", partial_us, " мкс, полностью ", full_us,
		" мкс; клеток высоты ", updated, "/", width * height)


func _test_direct_physics() -> void:
	var map := Map.new(Config.new(64, 48, 1729, 16, 32))
	var hydro := Hydro.new(map)
	hydro.rebuild()
	var surface := Surface.new(map, hydro)
	surface.rebuild()
	var climate := Climate.new(map, hydro)
	climate.rebuild()
	climate.set_day(24)
	surface.advance_climate_day(climate)
	hydro.apply_rainfall_map(surface.runoff_map())
	var processes := Natural.new(map, hydro, surface, climate)
	var accepted := 0
	for y in range(2, 48, 9):
		for x in range(2, 64, 11):
			var cell := Vector2i(x, y)
			var i: int = hydro.cell_index(cell)
			var soil: Dictionary = surface.profile_at(cell)
			var water: Dictionary = hydro.water_at(cell)
			var weather: Dictionary = climate.weather_at(cell)
			_check(soil["moisture"] == surface.moisture_at_index(i),
				"Быстрое чтение влажности совпадает с полным профилем")
			_check(soil["snow"] == surface.snow_at_index(i),
				"Быстрое чтение снега совпадает с полным профилем")
			_check(soil["depth"] == surface.soil_depth_at_index(i),
				"Толщина доступного грунта не меняется")
			_check(soil["erosion_risk"] == surface.erosion_risk_at_index(i),
				"Риск размыва не меняется")
			_check((soil["substrate"] == "скала") == surface.rock_at_index(i),
				"Скальная основа определяется прежним правилом")
			_check((soil["substrate"] in ["песок", "щебень"])
				== surface.exposed_at_index(i),
				"Рыхлые открытые породы совпадают")
			_check(water["discharge"] == hydro.discharge_at_index(i),
				"Расход реки совпадает с полным профилем")
			_check(weather["rainfall"] == climate.precipitation_at_index(i)
				* (1.0 - Climate.snowfall_fraction(
					climate.temperature_at_index(i))),
				"Для селей учитывается прежняя жидкая часть осадков")
			if not hydro.ocean_at(i) and not hydro.lake_at(i):
				accepted += 1
				var risk: Dictionary = processes.estimate_at(cell)
				for kind in ["water", "wind", "slide", "coast", "delta"]:
					_check(risk.has(kind) and float(risk[kind]) >= 0.0,
						"Оценка эрозии осталась физически допустимой")
	_check(accepted > 0, "Риски проверены на настоящей суше")


func _test_fault_cache() -> void:
	var map := Map.new(Config.new(128, 96, 5821, 16, 32))
	var hydro := Hydro.new(map)
	hydro.rebuild()
	var surface := Surface.new(map, hydro)
	surface.rebuild()
	var climate := Climate.new(map, hydro)
	climate.rebuild()
	var model := Disasters.new(map, hydro, surface, climate)
	var region := Vector2i(1, 1)
	var full: Dictionary = model._candidates(region, true)
	var brief: Dictionary = model._candidates(region, false)
	for kind in ["шторм", "паводок", "засуха", "землетрясение"]:
		_check(full[kind] == brief[kind],
			"Опасности без склонов дают прежние значения: " + kind)
	_check(float(brief["лавина"]["score"]) == 0.0,
		"В обычный день ненужный склон не вычисляется")
	var cached: int = model._fault_cache.size()
	_check(cached == 16, "Геологические зоны кэшируются по выборке")
	for cell in model._region_samples[region]:
		var expected := 1.0 - smoothstep(0.035, 0.28, absf(
			Terrain._noise((float(cell.x) + 37.0) / 140.0,
				(float(cell.y) + 19.0) / 140.0, map.config.world_seed + 4401)))
		_check(is_equal_approx(model.fault_risk_at(cell), expected),
			"Риск разлома совпадает с геологическим полем")
	model._candidates(region, false)
	_check(model._fault_cache.size() == cached,
		"Повторные погодные дни не вычисляют постоянные разломы")
	var first: Vector2i = model._region_samples[region][0]
	var fault_before: float = model.fault_risk_at(first)
	map.set_vertex(first, map.vertex_at(first) + 0.03)
	_check(model.fault_risk_at(first) == fault_before,
		"Локальный рельеф не меняет предопределённую геологию")


func _initialize() -> void:
	_test_hydrology(128, 96)
	_test_hydrology(256, 192)
	_test_fault_cache()
	_test_direct_physics()
	if not failures.is_empty():
		for reason in failures.slice(0, 20):
			push_error("Этап 7.3: " + reason)
		print("Нарушений инвариантов: ", failures.size())
		quit(1)
		return
	print("Этап 7.3: гидрология, кэш геологии и точность модели — успешно.")
	quit(0)
