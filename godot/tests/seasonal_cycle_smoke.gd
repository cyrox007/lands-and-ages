extends SceneTree
## Климатический год: плавные переходы и снег в разных зонах одной карты.

const WorldConfig = preload("res://scripts/world_config.gd")
const WorldMap = preload("res://scripts/world_map.gd")
const Hydrology = preload("res://scripts/hydrology.gd")
const Surface = preload("res://scripts/surface.gd")
const Climate = preload("res://scripts/climate.gd")
const Chunk = preload("res://scripts/chunk.gd")
const Landscape = preload("res://scripts/landscape_events.gd")

var failures: Array[String] = []


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _initialize() -> void:
	_run()


func _run() -> void:
	# Базовая карта: разные биомы должны сосуществовать одновременно.
	var world := WorldMap.new(WorldConfig.new())
	var hydro := Hydrology.new(world)
	hydro.rebuild()
	var climate := Climate.new(world, hydro)
	climate.rebuild()
	var surface := Surface.new(world, hydro)
	surface.rebuild()
	var biomes := {}
	for y in range(0, world.config.height, 8):
		for x in range(0, world.config.width, 8):
			biomes[climate.biome_at(Vector2i(x, y), surface)] = true
	_check(biomes.size() >= 7, "На стартовой карте есть широкий набор биомов")
	_check(biomes.has("пустыня") and biomes.has("полупустыня"),
		"В тёплом континентальном районе есть пустыни и полупустыни")
	_check(biomes.has("тундра") and biomes.has("умеренный лес"),
		"Холодные и умеренные зоны сосуществуют")
	print("Биомы стартовой карты: ", biomes.keys())

	# Поля температуры меняются на большой территории, но без резких скачков
	# в день смены названия сезона.
	var warm := 0
	var cold := 0
	var north: Vector2i = Vector2i(45, 12)
	var south: Vector2i = Vector2i(45, 180)
	climate.set_day(23)
	var before: float = climate.weather_at(north)["temperature"]
	climate.set_day(24)
	var after: float = climate.weather_at(north)["temperature"]
	_check(absf(after - before) < 3.0,
		"На границе весны и лета нет мгновенного температурного скачка")
	climate.set_day(47)
	before = climate.weather_at(south)["temperature"]
	climate.set_day(48)
	after = climate.weather_at(south)["temperature"]
	_check(absf(after - before) < 3.0,
		"На границе лета и осени нет температурного переключателя")
	climate.set_day(24)
	for y in range(0, world.config.height, 4):
		for x in range(0, world.config.width, 4):
			if float(climate.weather_at(Vector2i(x, y))["temperature"]) >= 0.0:
				warm += 1
	climate.set_day(72)
	for y in range(0, world.config.height, 4):
		for x in range(0, world.config.width, 4):
			if float(climate.weather_at(Vector2i(x, y))["temperature"]) >= 0.0:
				cold += 1
	_check(warm > cold + 200,
		"Летом большая доля карты теплее нуля, чем зимой")

	# У разных широт разное распределение осадков в течение года.
	climate.set_day(0)
	var north_spring: float = climate.weather_at(north)["seasonal_precipitation_factor"]
	climate.set_day(24)
	var north_summer: float = climate.weather_at(north)["seasonal_precipitation_factor"]
	var south_summer: float = climate.weather_at(south)["seasonal_precipitation_factor"]
	climate.set_day(72)
	var south_winter: float = climate.weather_at(south)["seasonal_precipitation_factor"]
	_check(north_spring > north_summer and south_summer > south_winter,
		"Сезонные осадки отличаются в холодных и тёплых широтах")
	_check(Climate.snowfall_fraction(30.0) == 0.0
		and Climate.snowfall_fraction(-10.0) == 1.0
		and Climate.snowfall_fraction(0.0) > 0.0
		and Climate.snowfall_fraction(0.0) < 1.0,
		"Дождь и снег переходят через смешанные осадки возле нуля")

	# Небольшая карта проходит весь год суточными шагами.
	# Выбираем отдельную карту, чтобы тест оставался быстрым в CI.
	var small_map := WorldMap.new(WorldConfig.new(96, 72, 1729))
	var small_hydro := Hydrology.new(small_map)
	small_hydro.rebuild()
	var small_surface := Surface.new(small_map, small_hydro)
	small_surface.rebuild()
	var small_climate := Climate.new(small_map, small_hydro)
	small_climate.rebuild()
	var summer_snow := 0.0
	var winter_snow := 0.0
	var largest_change := 0.0
	var previous_cover := 0.0
	for day in range(1, Climate.YEAR_DAYS + 1):
		small_climate.set_day(day)
		_check(small_surface.advance_climate_day(small_climate),
			"Снежный покров развивается по одному дню")
		_check(small_hydro.apply_rainfall_map(small_surface.runoff_map()),
			"Речной сток получает дождь и талую воду")
		var covered: float = small_surface.snow_coverage
		largest_change = maxf(largest_change, absf(covered - previous_cover))
		previous_cover = covered
		if day >= 26 and day <= 45:
			summer_snow += covered
		if day >= 77 and day <= 96:
			winter_snow += covered
	_check(winter_snow > summer_snow + 0.10,
		"Зимой снежный покров охватывает большую территорию")
	_check(largest_change < 0.30,
		"Снег не включается на огромной территории одним днём")

	# Растаявший снег питает водосборы, но не возникает при жаре.
	var cold_cell := Vector2i(10, 5)
	var warm_cell := Vector2i(50, 65)
	small_surface.advance_day(1.0, -12.0)
	var accumulated: float = small_surface.profile_at(cold_cell)["snow"]
	_check(accumulated > 0.0
		and small_surface.runoff_map()[small_hydro.cell_index(cold_cell)] < 0.01,
		"Зимние осадки накапливаются, а не мгновенно питают реку")
	small_surface.advance_day(0.0, 10.0)
	_check(small_surface.runoff_map()[small_hydro.cell_index(cold_cell)] > 0.0,
		"При оттепели возникает сток талой воды")
	_check(float(small_surface.profile_at(warm_cell)["snow"]) < 0.13,
		"Тёплый участок не покрывается снегом от соседнего холода")

	# Событие этапа 6.1 не запускает глобальную смену сезона.
	var event := Landscape.new(small_map)
	var far_cell := Vector2i(86, 6)
	var far_snow: float = small_surface.profile_at(far_cell)["snow"]
	var new_heights: Dictionary = event.apply("поднятие", Vector2(28.0, 39.0), 12.0, 2.0)
	_check(not new_heights.is_empty(), "Карта принимает геологическое событие")
	var changed_chunks: Array[Vector2i] = small_map.take_dirty_chunks()
	small_hydro.rebuild()
	small_climate.rebuild()
	small_surface.rebuild(changed_chunks)
	small_surface.synchronize_climate(small_climate)
	_check(is_equal_approx(float(small_surface.profile_at(far_cell)["snow"]), far_snow),
		"Изменение рельефа не стирает снег вдали")
	_check(small_climate.day == Climate.YEAR_DAYS,
		"Событие не переводит календарь в другой сезон")

	var snow_mesh := Chunk.create_mesh(0, 0, 1, small_map, small_surface,
		5, small_climate)
	_check(snow_mesh.get_surface_count() == 1
		and snow_mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR].size() > 0,
		"GPU поддерживает обзорный слой снега")

	if not failures.is_empty():
		for failure in failures:
			push_error("Сезоны: " + failure)
		quit(1)
		return
	print("Сезоны: плавные границы, распределение дождя и снега — успешно.")
	quit(0)
